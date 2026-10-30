import Foundation
import PhoneProtocol

/// Claude adapter driving the pinned Node helper (`ClaudeHost.mjs`) over a
/// line-JSON stdio protocol. The helper wraps `@anthropic-ai/claude-agent-sdk`
/// with streaming input + `resume`; this Swift side speaks the helper's
/// frame shape (v / type / id / method / body — spec: Claude).
///
/// The SDK version must be pinned to match Claude Code 2.1.239; a missing
/// or mismatched install keeps this adapter failing closed with
/// `cli_missing` / `adapter_failed` and the send switch stays off.
public final class ClaudeAdapter: @unchecked Sendable {
    public enum ClaudeError: Error {
        case cliMissing
        case adapterFailed(String)
    }

    public let binaries: AgentBinaries
    private let helperDirectory: URL
    private var processes: [String: LineRPCClient] = [:]
    private let lock = NSLock()
    private var nextFrameId = 0
    private var pendingPermissions: [String: (sessionId: String, requestId: String)] = [:]

    public var onEvent: (@Sendable (String, ConversationEvent) -> Void)?
    public var onApproval: (@Sendable (String, String, String, String) -> Void)?
    public var onTurnState: (@Sendable (String, String, String?) -> Void)?

    public init(binaries: AgentBinaries, appSupport: URL) {
        self.binaries = binaries
        self.helperDirectory = appSupport.appendingPathComponent("ClaudeHost")
        Self.installHelperIfNeeded(into: helperDirectory)
    }

    /// The helper .mjs is embedded as a bundle resource (single-file
    /// distribution, spec deviation for Layer ①) and staged into
    /// Application Support on first use, next to the pinned package.json.
    static func installHelperIfNeeded(into directory: URL) {
        let fm = FileManager.default
        let target = directory.appendingPathComponent("ClaudeHost.mjs")
        let packageTarget = directory.appendingPathComponent("package.json")
        guard !fm.fileExists(atPath: target.path) else { return }
        let bundle = Bundle.module
        guard let source = bundle.url(forResource: "ClaudeHost", withExtension: "mjs") else {
            BridgeLog.claude.error("ClaudeHost.mjs resource missing from bundle")
            return
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.copyItem(at: source, to: target)
        if let packageSource = bundle.url(forResource: "ClaudeHost.package", withExtension: "json") {
            try? fm.copyItem(at: packageSource, to: packageTarget)
        }
    }

    public var helperScriptPresent: Bool {
        if !FileManager.default.fileExists(atPath: helperDirectory.appendingPathComponent("ClaudeHost.mjs").path) {
            Self.installHelperIfNeeded(into: helperDirectory)
        }
        return FileManager.default.fileExists(atPath: helperDirectory.appendingPathComponent("ClaudeHost.mjs").path)
    }

    public func liveSessionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return processes.count
    }

    /// Open (or resume) a long-lived streaming-input session. `sessionId`
    /// nil means a brand-new conversation.
    @discardableResult
    public func openSession(sessionId: String?, cwd: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: binaries.claude),
              FileManager.default.fileExists(atPath: binaries.node) else {
            throw ClaudeError.cliMissing
        }
        guard helperScriptPresent else {
            throw ClaudeError.adapterFailed("ClaudeHost.mjs not installed")
        }
        if let sessionId, let existing = lock.locked({ processes[sessionId] }), existing.process.isRunning {
            return sessionId
        }
        let process = LineProcess(label: "claude-host")
        _ = try process.run(
            executable: binaries.node,
            arguments: [helperDirectory.appendingPathComponent("ClaudeHost.mjs").path],
            currentDirectory: cwd
        )
        let rpc = LineRPCClient(process: process, jsonRPCField: false)
        wire(rpc)
        let body: JSONValue = .object([
            "sessionId": sessionId.map { .string($0) } ?? .null,
            "cwd": .string(cwd),
            "claudeBinary": .string(binaries.claude),
            "settingSources": .array([.string("user"), .string("project")]),
        ])
        let result = try await rpc.request("session.open", params: body, timeout: 60)
        guard let resolved = result.objectValue?["sessionId"]?.stringValue, !resolved.isEmpty else {
            throw ClaudeError.adapterFailed("session.open returned no sessionId")
        }
        lock.lock()
        processes[resolved] = rpc
        lock.unlock()
        return resolved
    }

    public func prompt(sessionId: String, text: String, cwd: String, clientMessageId: String) async throws {
        let resolved = try await openSession(sessionId: sessionId, cwd: cwd)
        guard let rpc = lock.locked({ processes[resolved] }) else {
            throw ClaudeError.adapterFailed("session process missing")
        }
        _ = try await rpc.request("session.prompt", params: .object([
            "clientMessageId": .string(clientMessageId),
            "text": .string(text),
        ]), timeout: 600)
    }

    public func interrupt(sessionId: String) async throws {
        guard let rpc = lock.locked({ processes[sessionId] }) else { return }
        _ = try await rpc.request("session.interrupt", params: .object([:]), timeout: 15)
    }

    public func respondPermission(requestId: String, allowed: Bool) async throws {
        // Find the session that owns this permission request.
        let sessionId = lock.locked { () -> String? in
            for (key, value) in pendingPermissions where value.requestId == requestId {
                return key
            }
            return nil
        }
        guard let sessionId, let rpc = lock.locked({ processes[sessionId] }) else { return }
        _ = try await rpc.request("session.permission", params: .object([
            "requestId": .string(requestId),
            "behavior": .string(allowed ? "allow" : "deny"),
        ]), timeout: 15)
    }

    public func close(sessionId: String) async {
        guard let rpc = lock.locked({ processes.removeValue(forKey: sessionId) }) else { return }
        _ = try? await rpc.request("session.close", params: .object([:]), timeout: 15)
        rpc.process.terminate()
    }

    private func wire(_ rpc: LineRPCClient) {
        rpc.onNotification = { [weak self] method, params in
            guard let self else { return }
            let object = params.objectValue ?? [:]
            switch method {
            case "session.ready":
                let sessionId = object["sessionId"]?.stringValue ?? ""
                self.onTurnState?(sessionId, "ready", nil)
            case "session.event":
                self.handleHelperEvent(object)
            case "session.permission":
                let sessionId = object["sessionId"]?.stringValue ?? ""
                let requestId = object["requestId"]?.stringValue ?? ""
                let toolName = object["toolName"]?.stringValue ?? "tool"
                let preview = object["inputPreview"]?.stringValue ?? ""
                lock.lock()
                pendingPermissions[sessionId] = (sessionId, requestId)
                lock.unlock()
                self.onApproval?(sessionId, requestId, toolName, preview)
            default:
                break
            }
        }
        rpc.onServerRequest = { id, _, _ in
            // The helper never sends raw server requests; anything else is
            // refused fail-closed.
            try? rpc.respondError(id: id, code: -32000, message: "refused")
        }
    }

    private func handleHelperEvent(_ object: [String: JSONValue]) {
        guard let sessionId = object["sessionId"]?.stringValue,
              let body = object["body"]?.objectValue,
              let kind = body["kind"]?.stringValue else { return }
        let bodyValue: [String: JSONValue] = body
        let at = Int64(Date().timeIntervalSince1970 * 1000)
        switch kind {
        case "assistant_text_delta":
            onEvent?(sessionId, ConversationEvent(seq: 0, kind: .assistantTextDelta, text: bodyValue["text"]?.stringValue ?? "", at: at))
        case "thinking_delta":
            onEvent?(sessionId, ConversationEvent(seq: 0, kind: .thinkingDelta, text: bodyValue["text"]?.stringValue ?? "", at: at))
        case "tool_call":
            onEvent?(sessionId, ConversationEvent(seq: 0, kind: .toolCall, toolName: bodyValue["toolName"]?.stringValue, toolPreview: bodyValue["preview"]?.stringValue, toolStatus: .inProgress, callId: bodyValue["toolUseId"]?.stringValue, at: at))
        case "tool_result":
            onEvent?(sessionId, ConversationEvent(seq: 0, kind: .toolResult, toolPreview: bodyValue["preview"]?.stringValue, toolStatus: .completed, callId: bodyValue["toolUseId"]?.stringValue, at: at))
        case "user_message":
            onEvent?(sessionId, ConversationEvent(seq: 0, kind: .userMessage, text: bodyValue["text"]?.stringValue ?? "", at: at))
        case "turn_completed":
            onTurnState?(sessionId, "completed", nil)
        case "error":
            onTurnState?(sessionId, "failed", bodyValue["message"]?.stringValue)
        default:
            break
        }
    }
}

