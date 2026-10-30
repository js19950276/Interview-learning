import Foundation
import PhoneProtocol

/// Client for the bridge-owned `codex app-server --listen stdio://`
/// subprocess (codex-cli 0.165.0-alpha.1.2 on this machine). Line JSON-RPC
/// WITHOUT a `"jsonrpc"` field (spec Key Decision 1). Never proxies the
/// desktop `ipc.sock` and never calls `enable-remote-control`.
///
/// Open path is read-only (`thread/read` without `includeTurns`,
/// `thread/turns/list`, `thread/items/list`, one archived-retry via
/// `thread/unarchive`); sending performs `thread/unarchive` (if still
/// archived) → `thread/resume` → `turn/start` and `thread/unsubscribe` on
/// return to idle (spec: 活会话适配器 → Codex).
public final class CodexAppServer: @unchecked Sendable {
    public enum CodexError: Error {
        case binaryMissing
        case adapterFailed(String)
    }

    public static let supportedSandboxResume = "workspace-write"
    public static let turnSandboxPolicy: [String: Any] = [
        "type": "workspaceWrite",
        "networkAccess": false,
        "writableRoots": [String](),
    ]

    public let binaryPath: String
    private var rpc: LineRPCClient?
    private let lock = NSLock()
    private var started = false
    /// Output sink receiving normalized events keyed by thread id.
    public var onEvent: (@Sendable (String, ConversationEvent) -> Void)?
    /// Approval requests surfaced to the conversation manager.
    public var onApproval: (@Sendable (String, String, JSONValue, JSONValue) -> Void)?
    /// Turn lifecycle notifications (started/completed/diff…).
    public var onTurnState: (@Sendable (String, String, String?) -> Void)?

    public init(binaryPath: String) {
        self.binaryPath = binaryPath
    }

    // MARK: lifecycle

    /// Spawn (once) and `initialize` with full clientInfo (name AND version).
    public func ensureRunning() throws {
        lock.lock()
        defer { lock.unlock() }
        if started, let rpc, rpc.process.isRunning { return }
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw CodexError.binaryMissing
        }
        let process = LineProcess(label: "codex-app-server")
        _ = try process.run(
            executable: binaryPath,
            arguments: ["app-server", "--listen", "stdio://"],
            environment: ["CODEX_HOME": AgentBinaries.codexHome]
        )
        let client = LineRPCClient(process: process, jsonRPCField: false)
        client.onNotification = { [weak self] method, params in
            self?.handleNotification(method: method, params: params)
        }
        client.onServerRequest = { [weak self] id, method, params in
            self?.handleServerRequest(id: id, method: method, params: params)
        }
        rpc = client
        started = true
        Task.detached { [weak self] in
            guard let self else { return }
            _ = try? await client.request("initialize", params: JSONValue.object([
                "clientInfo": .object([
                    "name": .string(BridgeInfo.name),
                    "version": .string(BridgeInfo.version),
                ]),
            ]), timeout: 30)
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        rpc?.process.terminate()
        rpc = nil
        started = false
    }

    private func client() throws -> LineRPCClient {
        try ensureRunning()
        guard let rpc = lock.lock_sync({ rpc }) else {
            throw CodexError.adapterFailed("rpc missing")
        }
        return rpc
    }

    // MARK: read path

    public struct HistoryPage {
        public var events: [ConversationEvent]
        public var olderCursor: String?
    }

    /// Read-only history. If listing fails because the thread is archived,
    /// `thread/unarchive` once and retry (the only official write on the
    /// open path — spec Open step 4).
    public func readHistory(threadId: String) async throws -> HistoryPage {
        let client = try client()
        _ = try await client.request("thread/read", params: .object(["threadId": .string(threadId)]))
        do {
            return try await listHistory(client: client, threadId: threadId)
        } catch LineRPCClient.RPCError.errorResponse {
            _ = try? await client.request("thread/unarchive", params: .object(["threadId": .string(threadId)]))
            return try await listHistory(client: client, threadId: threadId)
        }
    }

    private func listHistory(client: LineRPCClient, threadId: String) async throws -> HistoryPage {
        // Newest turns first (default sortDirection descending); page until
        // we have a transcript window, then map items oldest-first.
        let turns = try await client.request("thread/turns/list", params: .object([
            "threadId": .string(threadId),
            "limit": .int(20),
        ]))
        var events: [ConversationEvent] = []
        var seq: Int64 = 1
        var turnIds: [(String, JSONValue)] = []
        if case .object(let fields) = turns,
           let turnsList = fields["turns"]?.arrayValue {
            for turn in turnsList.reversed() {
                guard let turnObject = turn.objectValue else { continue }
                let turnId = turnObject["id"]?.stringValue ?? ""
                if !turnId.isEmpty {
                    turnIds.append((turnId, turn))
                }
            }
        }
        if turnIds.isEmpty {
            // Fall back to a thread-wide item listing.
            let items = try await client.request("thread/items/list", params: .object([
                "threadId": .string(threadId),
                "limit": .int(200),
            ]))
            events = Self.mapItems(items, startSeq: &seq)
        } else {
            for (turnId, _) in turnIds {
                let items = try await client.request("thread/items/list", params: .object([
                    "threadId": .string(threadId),
                    "turnId": .string(turnId),
                    "limit": .int(100),
                ]))
                events.append(contentsOf: Self.mapItems(items, startSeq: &seq))
            }
        }
        return HistoryPage(events: events, olderCursor: nil)
    }

    static func mapItems(_ payload: JSONValue, startSeq: inout Int64) -> [ConversationEvent] {
        guard case .object(let fields) = payload,
              let items = fields["items"]?.arrayValue else { return [] }
        var events: [ConversationEvent] = []
        for item in items {
            guard let obj = item.objectValue else { continue }
            let type = obj["type"]?.stringValue ?? ""
            let id = obj["id"]?.stringValue
            let at = obj["timestamp"]?.doubleValue.map { Int64($0 * 1000) }
            switch type {
            case "message":
                let role = obj["role"]?.stringValue ?? "assistant"
                var text = ""
                if let content = obj["content"]?.arrayValue {
                    for piece in content {
                        if let p = piece.objectValue, p["type"]?.stringValue == "input_text" || p["type"]?.stringValue == "output_text" || p["type"]?.stringValue == "text" {
                            if let t = p["text"]?.stringValue { text += t }
                        }
                    }
                }
                if !text.isEmpty {
                    events.append(ConversationEvent(
                        seq: startSeq,
                        kind: role == "user" ? .userMessage : .assistantTextDelta,
                        text: text,
                        callId: id,
                        at: at
                    ))
                    startSeq += 1
                }
            case "reasoning":
                var text = ""
                if let summary = obj["summary"]?.arrayValue {
                    for piece in summary {
                        if let p = piece.objectValue, let t = p["text"]?.stringValue { text += t }
                    }
                }
                if !text.isEmpty {
                    events.append(ConversationEvent(seq: startSeq, kind: .thinkingDelta, text: text, callId: id, at: at))
                    startSeq += 1
                }
            case "command_execution":
                let command = obj["command"]?.stringValue ?? obj["program"]?.stringValue ?? "command"
                let aggregated = obj["aggregatedOutput"]?.stringValue ?? ""
                events.append(ConversationEvent(seq: startSeq, kind: .toolCall, toolName: "shell", toolPreview: command, toolStatus: .completed, callId: id, at: at))
                startSeq += 1
                if !aggregated.isEmpty {
                    events.append(ConversationEvent(seq: startSeq, kind: .toolResult, toolPreview: String(aggregated.prefix(2000)), toolStatus: .completed, callId: id, at: at))
                    startSeq += 1
                }
            case "file_change", "patch_apply":
                events.append(ConversationEvent(seq: startSeq, kind: .toolCall, toolName: "patch", toolPreview: nil, toolStatus: .completed, callId: id, at: at))
                startSeq += 1
            case "custom_tool_call":
                let name = obj["name"]?.stringValue ?? "tool"
                events.append(ConversationEvent(seq: startSeq, kind: .toolCall, toolName: name, toolPreview: nil, toolStatus: .inProgress, callId: id, at: at))
                startSeq += 1
            case "custom_tool_result", "tool_result":
                let output = obj["output"]?.stringValue ?? ""
                events.append(ConversationEvent(seq: startSeq, kind: .toolResult, toolPreview: String(output.prefix(2000)), toolStatus: .completed, callId: id, at: at))
                startSeq += 1
            default:
                continue
            }
        }
        return events
    }

    // MARK: send path

    /// Resume + start a turn. `thread/resume.sandbox` is the hyphenated
    /// string; `turn/start.sandboxPolicy` is the object — two different
    /// types (spec Key Decision 6).
    public func sendTurn(
        threadId: String,
        clientUserMessageId: String,
        text: String,
        archived: Bool
    ) async throws {
        let client = try client()
        if archived {
            _ = try await client.request("thread/unarchive", params: .object(["threadId": .string(threadId)]))
        }
        _ = try await client.request("thread/resume", params: .object([
            "threadId": .string(threadId),
            "sandbox": .string(Self.supportedSandboxResume),
        ]))
        _ = try await client.request("turn/start", params: .object([
            "threadId": .string(threadId),
            "input": .array([.object([
                "type": .string("text"),
                "text": .string(text),
            ])]),
            "approvalPolicy": .string("on-request"),
            "clientUserMessageId": .string(clientUserMessageId),
            "sandboxPolicy": .object([
                "type": .string("workspaceWrite"),
                "networkAccess": .bool(false),
                "writableRoots": .array([]),
            ]),
        ]))
    }

    public func unsubscribe(threadId: String) async {
        guard let client = lock.lock_sync({ rpc }) else { return }
        _ = try? await client.request("thread/unsubscribe", params: .object(["threadId": .string(threadId)]))
    }

    public func interrupt(threadId: String) async {
        guard let client = lock.lock_sync({ rpc }) else { return }
        _ = try? await client.request("turn/interrupt", params: .object(["threadId": .string(threadId)]))
    }

    // MARK: notifications (spec: 斜杠名, never PascalCase)

    private func handleNotification(method: String, params: JSONValue) {
        let object = params.objectValue ?? [:]
        let threadId = object["threadId"]?.stringValue ?? ""
        guard !threadId.isEmpty else { return }
        let at = Int64(Date().timeIntervalSince1970 * 1000)
        switch method {
        case "item/agentMessage/delta":
            if let delta = object["delta"]?.stringValue ?? object["text"]?.stringValue {
                emit(threadId, ConversationEvent(seq: 0, kind: .assistantTextDelta, text: delta, at: at))
            }
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            if let delta = object["delta"]?.stringValue ?? object["text"]?.stringValue {
                emit(threadId, ConversationEvent(seq: 0, kind: .thinkingDelta, text: delta, at: at))
            }
        case "turn/diff/updated", "item/fileChange/patchUpdated":
            var diff = object["diff"]?.stringValue ?? object["patch"]?.stringValue ?? ""
            if diff.isEmpty, let unified = object["unifiedDiff"]?.stringValue { diff = unified }
            if !diff.isEmpty {
                if diff.utf8.count > EventLimits.diffBytes {
                    diff = String(diff.prefix(EventLimits.diffBytes))
                }
                emit(threadId, ConversationEvent(seq: 0, kind: .diff, callId: object["itemId"]?.stringValue, diff: diff, at: at))
            }
        case "thread/tokenUsage/updated":
            let info = object["usage"]?.objectValue ?? object
            let usage = UsageDelta(
                inputTokens: info["inputTokens"]?.intValue ?? info["totalInputTokens"]?.intValue,
                outputTokens: info["outputTokens"]?.intValue ?? info["totalOutputTokens"]?.intValue,
                cacheReadTokens: info["cachedInputTokens"]?.intValue,
                cacheWriteTokens: info["cacheWriteTokens"]?.intValue
            )
            emit(threadId, ConversationEvent(seq: 0, kind: .usage, usage: usage, at: at))
        case "turn/started", "item/started":
            onTurnState?(threadId, "streaming", nil)
        case "turn/completed":
            onTurnState?(threadId, "completed", nil)
        case "turn/failed", "turn/error":
            onTurnState?(threadId, "failed", object["error"]?.stringValue)
        default:
            // Item lifecycle / command output notifications are mapped to
            // tool events when shapes are recognized; unknown names are
            // logged, never crash the adapter.
            BridgeLog.codex.debug("unmapped notification \(method, privacy: .public)")
        }
    }

    private func emit(_ threadId: String, _ event: ConversationEvent) {
        onEvent?(threadId, event)
    }

    // MARK: server requests (approval translation tables)

    /// Answer a pending server request for a phone decision. Returns the
    /// result frame to send. This implements the per-method tables from the
    /// spec (PR7): allow/deny/cancel per method family.
    public struct ServerReply {
        public var result: JSONValue?
        public var error: (code: Int, message: String)?
        public var followWithInterrupt: Bool
    }

    public static func reply(
        method: String,
        decision: String,          // "allow" | "deny" | "cancel"
        params: JSONValue
    ) -> ServerReply {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            switch decision {
            case "allow": return ServerReply(result: .object(["decision": .string("accept")]), error: nil, followWithInterrupt: false)
            case "deny": return ServerReply(result: .object(["decision": .string("decline")]), error: nil, followWithInterrupt: false)
            default: return ServerReply(result: .object(["decision": .string("cancel")]), error: nil, followWithInterrupt: false)
            }
        case "item/permissions/requestApproval":
            if decision == "allow" {
                // Copy the requested profile verbatim; scope stays "turn".
                let profile = params.objectValue?["permissions"] ?? .object([:])
                return ServerReply(result: .object(["permissions": profile, "scope": .string("turn")]), error: nil, followWithInterrupt: false)
            }
            // Deny / cancel / disconnect: empty grant, then interrupt.
            return ServerReply(result: .object(["permissions": .object([:]), "scope": .string("turn")]), error: nil, followWithInterrupt: true)
        case "execCommandApproval", "applyPatchApproval":
            switch decision {
            case "allow": return ServerReply(result: .object(["decision": .string("approved")]), error: nil, followWithInterrupt: false)
            case "deny": return ServerReply(result: .object(["decision": .object(["denied": .object(["rejection": .string("denied")])])]), error: nil, followWithInterrupt: false)
            default: return ServerReply(result: .object(["decision": .string("abort")]), error: nil, followWithInterrupt: false)
            }
        default:
            return refuse(method: method)
        }
    }

    /// Fail-closed answers for requests we never surface to the phone
    /// (spec: 同一 PR 里，其它服务器请求到达就回答).
    public static func refuse(method: String) -> ServerReply {
        switch method {
        case "item/tool/requestUserInput":
            return ServerReply(result: .object(["answers": .object([:])]), error: nil, followWithInterrupt: true)
        case "mcpServer/elicitation/request":
            return ServerReply(result: .object(["action": .string("decline")]), error: nil, followWithInterrupt: false)
        case "item/tool/call":
            return ServerReply(result: .object(["success": .bool(false), "contentItems": .array([])]), error: nil, followWithInterrupt: false)
        default:
            // account/chatgptAuthTokens/refresh, attestation/generate and
            // anything else: refused with an error, then interrupt.
            return ServerReply(result: nil, error: (-32000, "refused"), followWithInterrupt: true)
        }
    }

    private func handleServerRequest(id: JSONValue, method: String, params: JSONValue) {
        let threadId = params.objectValue?["threadId"]?.stringValue ?? ""
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/permissions/requestApproval",
             "execCommandApproval",
             "applyPatchApproval":
            onApproval?(threadId, method, id, params)
        default:
            // Refuse immediately; do not surface as approval_request.
            let refusal = Self.refuse(method: method)
            let client = lock.lock_sync { rpc }
            if let client {
                if let error = refusal.error {
                    try? client.respondError(id: id, code: error.code, message: error.message)
                } else if let result = refusal.result {
                    try? client.respond(id: id, result: result)
                }
                if refusal.followWithInterrupt, !threadId.isEmpty {
                    Task.detached { [weak self] in
                        await self?.interrupt(threadId: threadId)
                    }
                }
            }
            if refusal.followWithInterrupt, !threadId.isEmpty {
                onTurnState?(threadId, "failed", "unsupported_server_request")
            }
        }
    }

    /// Send the phone's decision for a pending request.
    public func respond(requestId: JSONValue, method: String, decision: String, params: JSONValue, threadId: String) async {
        guard let client = lock.lock_sync({ rpc }) else { return }
        let reply = Self.reply(method: method, decision: decision, params: params)
        if let error = reply.error {
            try? client.respondError(id: requestId, code: error.code, message: error.message)
        } else if let result = reply.result {
            try? client.respond(id: requestId, result: result)
        }
        if reply.followWithInterrupt {
            await interrupt(threadId: threadId)
        }
    }
}

private extension NSLock {
    func lock_sync<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
