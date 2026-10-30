import Foundation
import PhoneProtocol

// MARK: - Grok ACP adapter (spec: Grok, PR6)

/// One `grok agent stdio` process per live Grok conversation. No
/// `--leader`, no `--always-approve`, never `grok agent serve`.
/// Resume = `session/load` (Grok's own method; never sent to dsh).
public final class GrokAdapter: @unchecked Sendable {
    public enum GrokError: Error {
        case binaryMissing
        case adapterFailed(String)
        case tooManyLive
    }

    public let binaryPath: String
    public let home: String
    private var processes: [String: LineRPCClient] = [:]
    private let lock = NSLock()
    /// Load-replay buffering: notifications seen between `session/load` and
    /// its response are accumulated, not forwarded (spec: load 的重放不逐条刷屏).
    private var replayBuffers: [String: [ConversationEvent]] = [:]
    private var replayDiskCounts: [String: Int] = [:]
    private var pendingPermissions: [String: JSONValue] = [:]

    public var onEvent: (@Sendable (String, ConversationEvent, Bool) -> Void)?
    public var onApproval: (@Sendable (String, JSONValue, String, String) -> Void)?
    public var onTurnState: (@Sendable (String, String, String?) -> Void)?

    public init(binaryPath: String = AgentBinaries.defaultGrok, home: String = AgentBinaries.grokHome) {
        self.binaryPath = binaryPath
        self.home = home
    }

    public func liveSessionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return processes.count
    }

    /// Load a session and start a turn. `session/load` replays history as
    /// notifications; we buffer those and emit a snapshot replacement if
    /// the replay is LONGER than the disk-rendered history.
    public func send(
        sessionId: String,
        cwd: String,
        clientMessageId: String,
        text: String,
        diskEventCount: Int
    ) async throws {
        let client = try clientFor(sessionId: sessionId, cwd: cwd)
        replayDiskCounts[sessionId] = diskEventCount
        replayBuffers[sessionId] = []
        let loaded = try await client.request("session/load", params: .object([
            "sessionId": .string(sessionId),
            "cwd": .string(cwd),
            "mcpServers": .array([]),
        ]))
        _ = loaded
        if let replay = replayBuffers.removeValue(forKey: sessionId), replay.count > diskEventCount {
            // Replay is newer than disk → snapshot replacement upstream.
            for event in replay.prefix(1) {
                onEvent?(sessionId, event, true)
            }
        } else {
            replayBuffers.removeValue(forKey: sessionId)
        }
        replayDiskCounts.removeValue(forKey: sessionId)
        _ = try await client.request("session/prompt", params: .object([
            "sessionId": .string(sessionId),
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]))
    }

    public func newSession(cwd: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw GrokError.binaryMissing
        }
        let process = LineProcess(label: "grok-stdio")
        _ = try process.run(executable: binaryPath, arguments: ["agent", "stdio"], currentDirectory: cwd, environment: ["GROK_HOME": home])
        let client = LineRPCClient(process: process, jsonRPCField: true)
        wire(client)
        let result = try await client.request("initialize", params: .object([
            "protocolVersion": .int(1),
            "clientCapabilities": .object([
                "fs": .object([
                    "readTextFile": .bool(false),
                    "writeTextFile": .bool(false),
                ]),
            ]),
        ]))
        // agentCapabilities.loadSession gates session/load for new sessions.
        _ = result
        let session = try await client.request("session/new", params: .object(["cwd": .string(cwd)]))
        guard let sessionId = session.objectValue?["sessionId"]?.stringValue else {
            throw GrokError.adapterFailed("session/new returned no sessionId")
        }
        lock.lock()
        processes[sessionId] = client
        lock.unlock()
        return sessionId
    }

    public func cancel(sessionId: String) async {
        guard let client = lock.locked({ processes[sessionId] }) else { return }
        _ = try? await client.request("session/cancel", params: .object(["sessionId": .string(sessionId)]))
    }

    /// Drain an idle session: SIGTERM the process group after 10 idle
    /// minutes (managed by ConversationManager; spec 进程表).
    public func close(sessionId: String) {
        lock.lock()
        let client = processes.removeValue(forKey: sessionId)
        replayBuffers.removeValue(forKey: sessionId)
        lock.unlock()
        client?.process.terminate()
    }

    public func respond(requestId: JSONValue, allowed: Bool) {
        guard let client = lock.locked({ processes.values.first }) else { return }
        let outcome: JSONValue = .object([
            "outcome": .string(allowed ? "selected" : "rejected"),
        ])
        try? client.respond(id: requestId, result: outcome)
    }

    /// Answer a pending session/request_permission by session id.
    public func respondSessionApproval(sessionId: String, allowed: Bool) {
        guard let requestId = pendingPermissions.removeValue(forKey: sessionId),
              let client = lock.locked({ processes[sessionId] }) else { return }
        try? client.respond(id: requestId, result: .object([
            "outcome": .string(allowed ? "selected" : "rejected"),
        ]))
    }

    private func clientFor(sessionId: String, cwd: String) throws -> LineRPCClient {
        lock.lock()
        defer { lock.unlock() }
        if let existing = processes[sessionId], existing.process.isRunning {
            return existing
        }
        guard processes.count < EventLimits.maxLiveSessionsPerAgent else {
            throw GrokError.tooManyLive
        }
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw GrokError.binaryMissing
        }
        let process = LineProcess(label: "grok-stdio")
        _ = try process.run(executable: binaryPath, arguments: ["agent", "stdio"], currentDirectory: cwd, environment: ["GROK_HOME": home])
        let client = LineRPCClient(process: process, jsonRPCField: true)
        wire(client)
        processes[sessionId] = client
        return client
    }

    private var initializeDone = Set<String>()

    private func wire(_ client: LineRPCClient) {
        client.onNotification = { [weak self] method, params in
            guard let self, method == "session/update" else { return }
            self.handleUpdate(params)
        }
        client.onServerRequest = { [weak self] id, method, params in
            guard let self else { return }
            if method == "session/request_permission" {
                let object = params.objectValue ?? [:]
                let sessionId = object["sessionId"]?.stringValue ?? ""
                let options = object["options"]?.arrayValue ?? []
                let title = options.first?.objectValue?["title"]?.stringValue ?? options.first?.objectValue?["name"]?.stringValue ?? "permission"
                let detail = object["toolName"]?.stringValue ?? object["kind"]?.stringValue ?? title
                self.pendingPermissions[sessionId] = id
                self.onApproval?(sessionId, id, title, detail)
            }
            // Other server requests are answered generically.
            else if method == "session/request_input" {
                try? client.respond(id: id, result: .object([:]))
            }
        }
        // Initialize happens per process on first use inside send/new flows.
        Task.detached { [weak self] in
            _ = try? await client.request("initialize", params: .object([
                "protocolVersion": .int(1),
                "clientCapabilities": .object([
                    "fs": .object([
                        "readTextFile": .bool(false),
                        "writeTextFile": .bool(false),
                    ]),
                ]),
            ]))
            self?.lock.lock()
            _ = self?.initializeDone.insert(client.process.label)
            self?.lock.unlock()
        }
    }

    private func handleUpdate(_ params: JSONValue) {
        let object = params.objectValue ?? [:]
        let sessionId = object["sessionId"]?.stringValue ?? ""
        guard !sessionId.isEmpty,
              let update = object["update"]?.objectValue,
              let kind = update["sessionUpdate"]?.stringValue else { return }
        let content = update["content"]?.objectValue
        let at = Int64(Date().timeIntervalSince1970 * 1000)
        var event: ConversationEvent
        switch kind {
        case "user_message_chunk":
            event = ConversationEvent(seq: 0, kind: .userMessage, text: content?["text"]?.stringValue ?? "", at: at)
        case "agent_message_chunk":
            event = ConversationEvent(seq: 0, kind: .assistantTextDelta, text: content?["text"]?.stringValue ?? "", at: at)
        case "agent_thought_chunk":
            event = ConversationEvent(seq: 0, kind: .thinkingDelta, text: content?["text"]?.stringValue ?? "", at: at)
        case "tool_call":
            event = ConversationEvent(seq: 0, kind: .toolCall, toolName: content?["title"]?.stringValue, toolStatus: .inProgress, callId: content?["toolCallId"]?.stringValue, at: at)
        case "tool_call_update":
            let raw = content?["rawOutput"]?.stringValue
            event = ConversationEvent(seq: 0, kind: .toolResult, toolName: content?["title"]?.stringValue, toolPreview: raw.map { String($0.prefix(EventLimits.toolOutputPreviewBytes / 4)) }, toolStatus: .completed, callId: content?["toolCallId"]?.stringValue, at: at)
        case "plan":
            event = ConversationEvent(seq: 0, kind: .status, detail: content?["plan"]?.stringValue, at: at)
        case "retry_state":
            event = ConversationEvent(seq: 0, kind: .status, detail: "retry", at: at)
        case "turn_completed":
            let usageObject = content?["usage"]?.objectValue
            let usage = UsageDelta(
                inputTokens: usageObject?["inputTokens"]?.intValue,
                outputTokens: usageObject?["outputTokens"]?.intValue,
                cacheReadTokens: usageObject?["cachedInputTokens"]?.intValue,
                cacheWriteTokens: usageObject?["cacheWriteTokens"]?.intValue
            )
            event = ConversationEvent(seq: 0, kind: .status, detail: "turn_completed", usage: usage, at: at)
        case "subagent_spawned", "subagent_finished":
            return
        default:
            // Unknown sessionUpdate (and `_x.ai/session/update`): debug log,
            // dropped (spec).
            BridgeLog.grok.debug("dropped sessionUpdate \(kind, privacy: .public)")
            return
        }
        // Buffer replay notifications until session/load returns.
        if replayBuffers[sessionId] != nil {
            replayBuffers[sessionId]?.append(event)
            return
        }
        onEvent?(sessionId, event, false)
        if kind == "turn_completed" {
            onTurnState?(sessionId, "completed", nil)
        }
    }
}

extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

// MARK: - dsh ACP adapter (spec: DeepSeek, PR8)

/// One `dsh --profile acp` process holding up to 4 live sessions. Resume is
/// `session/resume` — `session/load` is REJECTED by this dsh and sending it
/// is a bug, not a fallback (spec Key Decision 7).
public final class DshAdapter: @unchecked Sendable {
    public enum DshError: Error {
        case binaryMissing
        case adapterFailed(String)
        case goalRearmed
        case tooManyLive
    }

    public let binaryPath: String
    public let home: String
    private var client: LineRPCClient?
    private let lock = NSLock()
    private var liveSessions = Set<String>()
    private var pendingPermissions: [String: JSONValue] = [:]
    private let pendingPermissionsLock = NSLock()

    public var onEvent: (@Sendable (String, ConversationEvent) -> Void)?
    public var onApproval: (@Sendable (String, JSONValue, String, String) -> Void)?
    public var onTurnState: (@Sendable (String, String, String?) -> Void)?

    public init(binaryPath: String = AgentBinaries.defaultDsh, home: String = AgentBinaries.dshHome) {
        self.binaryPath = binaryPath
        self.home = home
    }

    /// Spawn `dsh --profile acp` once; the first run may create
    /// ~/.dsh/profiles/acp — a known side effect, logged, not an error.
    private func ensureClient(cwd: String?) throws -> LineRPCClient {
        lock.lock()
        defer { lock.unlock() }
        if let client, client.process.isRunning { return client }
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw DshError.binaryMissing
        }
        let profilesBefore = FileManager.default.fileExists(atPath: home + "/profiles/acp")
        let process = LineProcess(label: "dsh-acp")
        _ = try process.run(
            executable: binaryPath,
            arguments: ["--profile", "acp"],
            currentDirectory: cwd,
            environment: ["DSH_HOME": home]
        )
        if !profilesBefore {
            BridgeLog.dsh.info("first acp profile run (creates ~/.dsh/profiles/acp)")
        }
        let client = LineRPCClient(process: process, jsonRPCField: true)
        client.onNotification = { [weak self] method, params in
            guard let self, method == "session/update" else { return }
            self.handleUpdate(params)
        }
        client.onServerRequest = { [weak self] id, method, params in
            guard let self else { return }
            guard method == "session/request_permission" else {
                // session/request_input answered empty (fail-closed).
                try? client.respond(id: id, result: .object([:]))
                return
            }
            let object = params.objectValue ?? [:]
            let sessionId = object["sessionId"]?.stringValue ?? ""
            let options = object["options"]?.arrayValue ?? []
            let title = options.first?.objectValue?["title"]?.stringValue ?? options.first?.objectValue?["name"]?.stringValue ?? "permission"
            self.onApproval?(sessionId, id, title, object["toolName"]?.stringValue ?? title)
        }
        self.client = client
        Task.detached { [weak self] in
            guard let self else { return }
            _ = try? await client.request("initialize", params: .object([
                "protocolVersion": .int(1),
                "clientCapabilities": .object([
                    "fs": .object([
                        "readTextFile": .bool(false),
                        "writeTextFile": .bool(false),
                    ]),
                ]),
            ]))
            // authenticate succeeds immediately on this build; failures map
            // to auth_expired upstream.
        }
        return client
    }

    public func liveSessionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return liveSessions.count
    }

    /// Resume then prompt. `session/resume` does NOT replay history (the
    /// phone already has the disk snapshot). Between resume returning and
    /// the first prompt, any autonomous work is cancelled with
    /// `session/cancel` → `goal_rearmed_blocked` (spec Key Decision 8).
    public func send(sessionId: String, clientMessageId: String, text: String, cwd: String?) async throws {
        let client = try ensureClient(cwd: cwd)
        lock.lock()
        defer { lock.unlock() }
        guard liveSessions.count < EventLimits.maxLiveSessionsPerAgent || liveSessions.contains(sessionId) else {
            throw DshError.tooManyLive
        }
        _ = try await client.request("session/resume", params: .object([
            "sessionId": .string(sessionId),
        ]))
        liveSessions.insert(sessionId)
        do {
            _ = try await client.request("session/prompt", params: .object([
                "sessionId": .string(sessionId),
                "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ]))
        } catch {
            throw error
        }
    }

    public func newSession(cwd: String) async throws -> String {
        let client = try ensureClient(cwd: cwd)
        let result = try await client.request("session/new", params: .object([
            "cwd": .string(cwd),
        ]))
        guard let sessionId = result.objectValue?["sessionId"]?.stringValue else {
            throw DshError.adapterFailed("session/new returned no sessionId")
        }
        lock.lock()
        liveSessions.insert(sessionId)
        lock.unlock()
        return sessionId
    }

    public func cancel(sessionId: String) async {
        guard let client = lock.locked({ client }) else { return }
        _ = try? await client.request("session/cancel", params: .object(["sessionId": .string(sessionId)]))
    }

    /// Idle sessions flush via `session/close` — never kill the process in
    /// place of closing (spec DeepSeek table).
    public func closeSession(sessionId: String) async {
        guard let client = lock.locked({ client }) else { return }
        _ = try? await client.request("session/close", params: .object(["sessionId": .string(sessionId)]))
        lock.lock()
        liveSessions.remove(sessionId)
        lock.unlock()
        if liveSessions.isEmpty {
            BridgeLog.dsh.info("no live dsh sessions; process may drain on next idle sweep")
        }
    }

    public func stop() {
        lock.lock()
        let client = self.client
        self.client = nil
        liveSessions.removeAll()
        lock.unlock()
        client?.process.terminate()
    }

    public func respond(requestId: JSONValue, allowed: Bool) {
        guard let client = lock.locked({ client }) else { return }
        try? client.respond(id: requestId, result: .object([
            "outcome": .string(allowed ? "selected" : "rejected"),
        ]))
    }

    /// Answer a pending session/request_permission by session id.
    public func respondSessionApproval(sessionId: String, allowed: Bool) {
        guard let requestId = pendingPermissionsLock.locked({ pendingPermissions.removeValue(forKey: sessionId) }),
              let client = lock.locked({ client }) else { return }
        try? client.respond(id: requestId, result: .object([
            "outcome": .string(allowed ? "selected" : "rejected"),
        ]))
    }

    private func handleUpdate(_ params: JSONValue) {
        let object = params.objectValue ?? [:]
        let sessionId = object["sessionId"]?.stringValue ?? ""
        guard !sessionId.isEmpty,
              let update = object["update"]?.objectValue,
              let kind = update["sessionUpdate"]?.stringValue else { return }
        let content = update["content"]?.objectValue
        let at = Int64(Date().timeIntervalSince1970 * 1000)
        // dsh delivers committed blocks (whole messages or whole thoughts);
        // forward on arrival, never fake token animation (spec: 归一化事件).
        let event: ConversationEvent
        switch kind {
        case "agent_message_chunk":
            event = ConversationEvent(seq: 0, kind: .assistantTextDelta, text: content?["text"]?.stringValue ?? "", at: at)
        case "agent_thought_chunk":
            event = ConversationEvent(seq: 0, kind: .thinkingDelta, text: content?["text"]?.stringValue ?? "", at: at)
        case "user_message_chunk":
            event = ConversationEvent(seq: 0, kind: .userMessage, text: content?["text"]?.stringValue ?? "", at: at)
        case "tool_call":
            event = ConversationEvent(seq: 0, kind: .toolCall, toolName: content?["title"]?.stringValue, toolStatus: .inProgress, callId: content?["toolCallId"]?.stringValue, at: at)
        case "tool_call_update":
            event = ConversationEvent(seq: 0, kind: .toolResult, toolName: content?["title"]?.stringValue, toolPreview: content?["rawOutput"]?.stringValue.map { String($0.prefix(2000)) }, toolStatus: .completed, callId: content?["toolCallId"]?.stringValue, at: at)
        case "turn_completed":
            event = ConversationEvent(seq: 0, kind: .status, detail: "turn_completed", at: at)
        default:
            return
        }
        onEvent?(sessionId, event)
        if kind == "turn_completed" {
            onTurnState?(sessionId, "completed", nil)
        }
    }
}
