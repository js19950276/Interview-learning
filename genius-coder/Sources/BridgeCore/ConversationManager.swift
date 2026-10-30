import Foundation
import PhoneProtocol

/// Per-agent send switches, persisted in `settings.json` under Application
/// Support. All default OFF; a switch may only be enabled by the human in
/// the menu bar once that agent's approval/writer/caffeinate/ring/disconnect
/// fail-closed pieces all shipped together (spec Key Decision 13).
public struct SendSwitches: Codable, Equatable {
    public var codex: Bool = false
    public var claude: Bool = false
    public var grok: Bool = false
    public var deepseek: Bool = false

    public init() {}

    public func isEnabled(_ agent: AgentKind) -> Bool {
        switch agent {
        case .codex: return codex
        case .claude: return claude
        case .grok: return grok
        case .deepseek: return deepseek
        }
    }

    public mutating func set(_ agent: AgentKind, _ value: Bool) {
        switch agent {
        case .codex: codex = value
        case .claude: claude = value
        case .grok: grok = value
        case .deepseek: deepseek = value
        }
    }

    public static func load(from directory: URL) -> SendSwitches {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
              let decoded = try? JSONDecoder().decode(SendSwitches.self, from: data) else {
            return SendSwitches()
        }
        return decoded
    }

    public func save(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: directory.appendingPathComponent("settings.json"), options: .atomic)
        }
    }
}

/// Central conversation state machine (spec: 会话状态机). Owns open/send/
/// cancel/approval routing, seq assignment, event fan-out to phone
/// sessions and the catch-up rings.
public final class ConversationManager: @unchecked Sendable {
    public struct LiveConversation {
        public var row: IndexedConversation
        public var summary: ConversationSummary
        public var phase: SessionPhase = .idle
        public var writer: SessionWriter = .none
        public var detail: String?
        public var history: [ConversationEvent] = []
        public var liveEvents: [ConversationEvent] = []
        public var nextSeq: Int64 = 1
        public var lastDeliveredSeq: Int64 = 0
        public var ring = CatchUpRing()
        public var writerLease: WriterLease?
        public var pendingApprovals: [String: PendingApproval] = [:]
        public var clientMessageIds: [String: Date] = [:]

        public struct PendingApproval {
            public var serverMethod: String
            public var params: JSONValue
            public var agent: AgentKind
            public var nativeSessionId: String
            public var requestIdValue: JSONValue?
            public var nativeRequestId: String = ""
        }
    }

    private let queue = DispatchQueue(label: "genius-coder.conversations")
    private var live: [String: LiveConversation] = [:]
    private let indexStore: IndexStore
    private let binaries: AgentBinaries
    private let caffeinate: Caffeinate
    private var switches: SendSwitches
    private let writerLock: WriterLock
    private var approvalSeq = 0

    /// Outbound event sink: the BridgeServer registers one per authenticated
    /// phone session plus the rings.
    public var broadcast: (@Sendable (WireEnvelope) -> Void)?

    // Adapters (lazily created; owned here).
    public private(set) var grok: GrokAdapter?
    public private(set) var dsh: DshAdapter?
    public private(set) var codex: CodexAppServer?
    public private(set) var claude: ClaudeAdapter?

    public init(indexStore: IndexStore, binaries: AgentBinaries, appSupport: URL) {
        self.indexStore = indexStore
        self.binaries = binaries
        self.caffeinate = Caffeinate()
        self.switches = SendSwitches.load(from: appSupport)
        self.writerLock = WriterLock()
        self.grok = GrokAdapter(binaryPath: binaries.grok)
        self.dsh = DshAdapter(binaryPath: binaries.dsh)
        self.codex = CodexAppServer(binaryPath: binaries.codex)
        self.claude = ClaudeAdapter(binaries: binaries, appSupport: appSupport)
        wireAdapters()
    }

    public func sendSwitches() -> SendSwitches {
        queue.sync { switches }
    }

    public func setSendSwitch(_ agent: AgentKind, _ value: Bool, saveTo directory: URL) {
        queue.sync {
            switches.set(agent, value)
        }
        switches.save(to: directory)
    }

    private func wireAdapters() {
        grok?.onEvent = { [weak self] sessionId, event, isReplay in
            guard let self, !isReplay else { return }
            self.appendLive("grok:\(sessionId)", event)
        }
        grok?.onTurnState = { [weak self] sessionId, phase, detail in
            guard let self else { return }
            self.handleTurnState("grok:\(sessionId)", phase: phase, detail: detail)
        }
        grok?.onApproval = { [weak self] sessionId, requestId, toolName, detail in
            guard let self else { return }
            self.registerApproval(agent: .grok, conversationId: "grok:\(sessionId)", nativeSessionId: sessionId, serverMethod: "session/request_permission", params: .object([
                "sessionId": .string(sessionId),
                "toolName": .string(toolName),
            ]), requestId: requestId, title: toolName, detail: detail)
        }
        dsh?.onEvent = { [weak self] sessionId, event in
            guard let self else { return }
            self.appendLive("deepseek:session-\(sessionId)".replacingOccurrences(of: "session-session-", with: "session-"), event)
        }
        dsh?.onTurnState = { [weak self] sessionId, phase, detail in
            guard let self else { return }
            let conversationId = sessionId.hasPrefix("session-") ? "deepseek:\(sessionId)" : "deepseek:\(sessionId)"
            self.handleTurnState(conversationId, phase: phase, detail: detail)
        }
        dsh?.onApproval = { [weak self] sessionId, requestId, toolName, detail in
            guard let self else { return }
            let conversationId = sessionId.hasPrefix("session-") ? "deepseek:\(sessionId)" : "deepseek:\(sessionId)"
            self.registerApproval(agent: .deepseek, conversationId: conversationId, nativeSessionId: sessionId, serverMethod: "session/request_permission", params: .object([
                "sessionId": .string(sessionId),
                "toolName": .string(toolName),
            ]), requestId: requestId, title: toolName, detail: detail)
        }
        codex?.onEvent = { [weak self] threadId, event in
            guard let self else { return }
            self.appendLive("codex:\(threadId)", event)
        }
        codex?.onTurnState = { [weak self] threadId, phase, detail in
            guard let self else { return }
            self.handleTurnState("codex:\(threadId)", phase: phase, detail: detail)
        }
        codex?.onApproval = { [weak self] threadId, serverMethod, requestId, params in
            guard let self else { return }
            self.registerApproval(agent: .codex, conversationId: "codex:\(threadId)", nativeSessionId: threadId, serverMethod: serverMethod, params: params, requestId: requestId, title: Self.approvalTitle(method: serverMethod), detail: nil)
        }
        claude?.onEvent = { [weak self] sessionId, event in
            guard let self else { return }
            self.appendLive("claude:\(sessionId)", event)
        }
        claude?.onTurnState = { [weak self] sessionId, phase, detail in
            guard let self else { return }
            self.handleTurnState("claude:\(sessionId)", phase: phase, detail: detail)
        }
        claude?.onApproval = { [weak self] sessionId, requestId, toolName, detail in
            guard let self else { return }
            self.registerApproval(agent: .claude, conversationId: "claude:\(sessionId)", nativeSessionId: requestId, serverMethod: "claude.permission", params: .object([:]), requestId: .string(requestId), title: toolName, detail: detail)
        }
    }

    static func approvalTitle(method: String) -> String {
        switch method {
        case "item/commandExecution/requestApproval": return "Run command"
        case "item/fileChange/requestApproval": return "Apply file change"
        case "item/permissions/requestApproval": return "Permission upgrade"
        case "execCommandApproval": return "Run command (legacy)"
        case "applyPatchApproval": return "Apply patch (legacy)"
        default: return "Approval"
        }
    }

    // MARK: open / history (read-only, spec PR4)

    public func open(conversationId: String) -> Result<ConversationOpenResponse, PhoneErrorCode> {
        guard let id = ConversationID(rawValue: conversationId) else {
            return .failure(.notFound)
        }
        guard let row = indexStore.conversation(id) else {
            return .failure(.notFound)
        }
        if !row.resumable {
            let _ = row
        }
        if let existing = queue.sync(execute: { live[conversationId] }) {
            let pager = HistoryPager(events: existing.history + existing.liveEvents)
            let page = pager.newestPage()
            return .success(ConversationOpenResponse(
                conversation: existing.summary,
                state: SessionState(phase: existing.phase, connection: .connected, writer: existing.writer, detail: existing.detail),
                events: page.events,
                nextSeq: existing.nextSeq,
                olderCursor: page.olderCursor
            ))
        }

        // History sources per agent (spec Key Decision 2).
        var events: [ConversationEvent] = []
        var detail: String? = nil
        var error: PhoneErrorCode? = nil
        switch id.agent {
        case .grok:
            if row.emptyHistory || row.sourcePath == nil {
                detail = PhoneErrorCode.emptyHistory.rawValue
            } else if let dir = row.sourcePath {
                events = GrokHistory.load(sessionDirectory: dir)
            }
        case .deepseek:
            guard let path = row.sourcePath else {
                error = .sessionUnreadable
                break
            }
            let parsed = DshHistory.load(logPath: path)
            if let failure = parsed.error {
                error = failure
            } else {
                events = parsed.events
            }
        case .codex:
            // Read-only via the bridge-owned app-server; file parsers and
            // zstd decompression are forbidden here (spec).
            let semaphore = DispatchSemaphore(value: 0)
            var box: Result<CodexAppServer.HistoryPage, Error> = .failure(PhoneErrorCode.adapterFailed)
            Task.detached { [weak self] in
                guard let self, let codex = self.codex else {
                    semaphore.signal()
                    return
                }
                do {
                    box = .success(try await codex.readHistory(threadId: id.nativeID))
                } catch {
                    box = .failure(error)
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 45)
            if case .success(let page) = box {
                events = page.events
            } else if case .failure(let failure) = box {
                if case CodexAppServer.CodexError.binaryMissing = failure {
                    error = PhoneErrorCode.cliMissing
                } else {
                    error = .adapterFailed
                }
            }
        case .claude:
            error = .claudeHistoryNeedsFixture
        }

        let resumable = row.resumable && error == nil
        var summary = ConversationSummary(
            conversationId: conversationId,
            agent: row.agent,
            projectId: "",
            title: row.title,
            updatedAt: row.updatedAt,
            archived: row.archived,
            resumable: resumable,
            resumableError: error?.rawValue ?? row.resumableError,
            parentConversationId: nil,
            detail: row.emptyHistory ? PhoneErrorCode.emptyHistory.rawValue : detail
        )
        _ = summary.detail

        queue.sync {
            var state = LiveConversation(row: row, summary: summary)
            state.history = events
            state.nextSeq = Int64(events.count) + 1
            state.detail = detail
            if !resumable {
                state.phase = .unavailable
                summary.resumable = false
            }
            state.summary = summary
            live[conversationId] = state
        }
        let snapshot = queue.sync { live[conversationId]! }
        let pager = HistoryPager(events: snapshot.history)
        let page = pager.newestPage()
        return .success(ConversationOpenResponse(
            conversation: summary,
            state: SessionState(
                phase: snapshot.phase,
                connection: .connected,
                writer: .none,
                detail: snapshot.detail
            ),
            events: page.events,
            nextSeq: snapshot.nextSeq,
            olderCursor: page.olderCursor
        ))
    }

    public func history(conversationId: String, cursor: String?) -> Result<ConversationHistoryResponse, PhoneErrorCode> {
        queue.sync {
            guard let state = live[conversationId] else { return .failure(.notFound) }
            let pager = HistoryPager(events: state.history + state.liveEvents)
            if let cursor {
                guard let page = pager.page(cursor: cursor) else {
                    return .failure(.notFound)
                }
                return .success(ConversationHistoryResponse(events: page.events, olderCursor: page.olderCursor))
            }
            let page = pager.newestPage()
            return .success(ConversationHistoryResponse(events: page.events, olderCursor: page.olderCursor))
        }
    }

    // MARK: send / cancel / approval

    public func send(conversationId: String, clientMessageId: String, text: String) -> Result<Void, PhoneErrorCode> {
        guard text.utf8.count <= EventLimits.maxTextBytes else {
            return .failure(.malformedRequest)
        }
        guard let id = ConversationID(rawValue: conversationId) else {
            return .failure(.notFound)
        }
        let row = indexStore.conversation(id)
        guard let row else { return .failure(.notFound) }
        guard row.resumable else { return .failure(.notResumable) }

        let enabled = queue.sync { switches.isEnabled(id.agent) }
        guard enabled else { return .failure(.sendDisabled) }

        // Idempotency: the same clientMessageId never starts a second turn.
        // The live state is created here if the conversation was never
        // opened, so the id is always recorded on first send.
        let duplicate = queue.sync { () -> Bool in
            var state = live[conversationId] ?? {
                var created = LiveConversation(row: row, summary: ConversationSummary(
                    conversationId: conversationId,
                    agent: row.agent,
                    projectId: "",
                    title: row.title,
                    updatedAt: row.updatedAt,
                    archived: row.archived,
                    resumable: row.resumable,
                    resumableError: row.resumableError
                ))
                created.nextSeq = 1
                return created
            }()
            pruneClientMessageIds(&state)
            if state.clientMessageIds[clientMessageId] != nil {
                live[conversationId] = state
                return true
            }
            state.clientMessageIds[clientMessageId] = Date()
            live[conversationId] = state
            return false
        }
        if duplicate { return .success(()) }

        // Writer exclusion (spec: 写入者锁). On conflict → read_only.
        let lockFile: String?
        let watchPaths: [String]
        switch id.agent {
        case .grok:
            lockFile = row.sourcePath.map { $0 + "/updates.jsonl.lock" }
            watchPaths = row.sourcePath.map { [$0 + "/updates.jsonl"] } ?? []
        case .deepseek:
            lockFile = row.sourcePath.map { ($0 as NSString).deletingLastPathComponent + "/session.lock" }
            watchPaths = row.sourcePath.map { [$0] } ?? []
        case .codex:
            lockFile = nil // thread-writer-locks only if present at send time
            watchPaths = row.sourcePath.map { [$0] } ?? []
        case .claude:
            lockFile = nil
            watchPaths = row.sourcePath.map { [$0] } ?? []
        }
        let acquired = writerLock.acquire(
            conversationId: conversationId,
            lockFile: lockFile,
            watchPaths: watchPaths,
            agentProcessNames: [id.agent.rawValue]
        )
        switch acquired {
        case .locked:
            queue.sync {
                live[conversationId]?.phase = .readOnly
                live[conversationId]?.writer = .desktop
            }
            pushState(conversationId)
            return .failure(.writerLocked)
        case .acquired(let lease):
            queue.sync {
                live[conversationId]?.phase = .streaming
                live[conversationId]?.writer = .bridge
                live[conversationId]?.writerLease = lease
            }
            pushState(conversationId)
            caffeinate.beginTurn()
            emitLocal(conversationId, ConversationEvent(
                seq: 0,
                kind: .userMessage,
                text: text,
                clientMessageId: clientMessageId
            ))
            Task.detached { [weak self] in
                guard let self else { return }
                await self.runSend(id: id, row: row, text: text, clientMessageId: clientMessageId, lease: lease)
            }
            return .success(())
        }
    }

    private func runSend(id: ConversationID, row: IndexedConversation, text: String, clientMessageId: String, lease: WriterLease) async {
        let conversationId = id.rawValue
        let diskCount = queue.sync { live[conversationId]?.history.count ?? 0 }
        do {
            switch id.agent {
            case .grok:
                guard let grok else { throw PhoneErrorCode.adapterFailed }
                try await grok.send(sessionId: id.nativeID, cwd: row.cwd, clientMessageId: clientMessageId, text: text, diskEventCount: diskCount)
            case .deepseek:
                guard let dsh else { throw PhoneErrorCode.adapterFailed }
                try await dsh.send(sessionId: id.nativeID, clientMessageId: clientMessageId, text: text, cwd: row.cwd)
            case .codex:
                guard let codex else { throw PhoneErrorCode.adapterFailed }
                try await codex.sendTurn(threadId: id.nativeID, clientUserMessageId: clientMessageId, text: text, archived: row.archived)
            case .claude:
                guard let claude else { throw PhoneErrorCode.adapterFailed }
                try await claude.prompt(sessionId: id.nativeID, text: text, cwd: row.cwd, clientMessageId: clientMessageId)
            }
        } catch {
            queue.sync {
                live[conversationId]?.phase = .failed
                live[conversationId]?.detail = "adapter_failed"
            }
            pushState(conversationId)
            caffeinate.endTurnIfNeeded()
            lease.release()
            emitLocal(conversationId, ConversationEvent(seq: 0, kind: .status, detail: "adapter_failed"))
            return
        }
        // The turn completes via turn_completed notifications; the lease is
        // released when the phase returns to idle (handleTurnState).
    }

    public func cancel(conversationId: String) -> Result<Void, PhoneErrorCode> {
        guard let id = ConversationID(rawValue: conversationId) else {
            return .failure(.notFound)
        }
        queue.sync {
            guard let state = live[conversationId], state.phase == .streaming || state.phase == .needsApproval else {
                return
            }
        }
        Task.detached { [weak self] in
            guard let self else { return }
            switch id.agent {
            case .grok: await self.grok?.cancel(sessionId: id.nativeID)
            case .deepseek: await self.dsh?.cancel(sessionId: id.nativeID)
            case .codex: await self.codex?.interrupt(threadId: id.nativeID)
            case .claude: try? await self.claude?.interrupt(sessionId: id.nativeID)
            }
            self.finishTurn(conversationId, phase: .idle, detail: nil)
        }
        return .success(())
    }

    public func approve(conversationId: String, approvalId: String, optionId: String) -> Result<Void, PhoneErrorCode> {
        guard ApprovalOption.isValid(optionId) else { return .failure(.malformedRequest) }
        let pending = queue.sync { live[conversationId]?.pendingApprovals.removeValue(forKey: approvalId) }
        guard let pending else { return .failure(.notFound) }
        let allowed = optionId == "allow"
        emitLocal(conversationId, ConversationEvent(
            seq: 0,
            kind: .approvalResolved,
            approvalId: approvalId,
            detail: optionId
        ))
        Task.detached { [weak self] in
            guard let self else { return }
            switch pending.agent {
            case .grok:
                self.grok?.respond(requestId: pending.params.objectValue?["sessionId"].map { _ in JSONValue.null } ?? .null, allowed: allowed)
                // Grok/dsh approvals answer on their own request id, which
                // registerApproval stored inside params; adapters resolve it.
                self.resolveAcpApproval(agent: .grok, pending: pending, allowed: allowed)
            case .deepseek:
                self.resolveAcpApproval(agent: .deepseek, pending: pending, allowed: allowed)
            case .codex:
                if let requestId = pending.requestIdValue {
                    await self.codex?.respond(
                        requestId: requestId,
                        method: pending.serverMethod,
                        decision: optionId,
                        params: pending.params,
                        threadId: pending.nativeSessionId
                    )
                }
            case .claude:
                try? await self.claude?.respondPermission(requestId: pending.nativeRequestId, allowed: allowed)
            }
            // Deny on permission upgrades ends the turn (spec: 手机上的 Deny).
            if !allowed {
                let endsTurn = pending.serverMethod == "item/permissions/requestApproval" || pending.serverMethod == "claude.permission"
                if endsTurn {
                    await self.codex?.interrupt(threadId: pending.nativeSessionId)
                    self.finishTurn(conversationId, phase: .idle, detail: nil)
                } else {
                    self.queue.sync(execute: { self.live[conversationId]?.phase = .streaming })
                    self.pushState(conversationId)
                }
            } else {
                self.queue.sync(execute: { self.live[conversationId]?.phase = .streaming })
                self.pushState(conversationId)
            }
        }
        return .success(())
    }

    private func resolveAcpApproval(agent: AgentKind, pending: LiveConversation.PendingApproval, allowed: Bool) {
        // The ACP adapters keep their own request-id maps; route by session.
        let sessionId = pending.nativeSessionId
        if agent == .grok {
            grok?.respondSessionApproval(sessionId: sessionId, allowed: allowed)
        } else {
            dsh?.respondSessionApproval(sessionId: sessionId, allowed: allowed)
        }
    }

    // MARK: event plumbing

    func appendLive(_ conversationId: String, _ event: ConversationEvent) {
        var envelope = event
        guard var state = queue.sync(execute: { live[conversationId] }) else { return }
        envelope.seq = state.nextSeq
        state.nextSeq += 1
        state.liveEvents.append(envelope)
        if envelope.kind == .approvalRequest {
            // Approval cards are stored keyed by approvalId in the adapter
            // layer via registerApproval; here we just fan out.
        }
        state.ring.append(envelope)
        queue.sync(execute: { self.live[conversationId] = state })
        broadcast?(WireEnvelope.event(
            method: PhoneMethod.conversationEventMethod,
            body: JSONValue.from(ConversationEventBody(conversationId: conversationId, event: envelope))
        ))
        _ = state
    }

    private func emitLocal(_ conversationId: String, _ event: ConversationEvent) {
        appendLive(conversationId, event)
    }

    func handleTurnState(_ conversationId: String, phase: String, detail: String?) {
        switch phase {
        case "streaming":
            queue.sync {
                live[conversationId]?.phase = .streaming
                live[conversationId]?.writer = .bridge
            }
        case "completed":
            finishTurn(conversationId, phase: .idle, detail: nil)
        case "failed":
            finishTurn(conversationId, phase: .failed, detail: detail ?? "adapter_failed")
        default:
            break
        }
        pushState(conversationId)
    }

    private func finishTurn(_ conversationId: String, phase: SessionPhase, detail: String?) {
        queue.sync {
            live[conversationId]?.phase = phase
            live[conversationId]?.detail = detail
            if phase == .idle {
                live[conversationId]?.writer = .none
            }
        }
        pushState(conversationId)
        caffeinate.endTurnIfNeeded()
        let lease = queue.sync { live[conversationId]?.writerLease }
        lease?.release()
        if phase == .idle, let id = ConversationID(rawValue: conversationId) {
            switch id.agent {
            case .codex:
                Task.detached { [weak self] in
                    await self?.codex?.unsubscribe(threadId: id.nativeID)
                }
            case .deepseek:
                Task.detached { [weak self] in
                    // Idle sessions flush to disk via session/close.
                    await self?.dsh?.closeSession(sessionId: id.nativeID)
                }
            default:
                break
            }
        }
    }

    private func pushState(_ conversationId: String) {
        let state = queue.sync { live[conversationId].map {
            SessionState(phase: $0.phase, connection: .connected, writer: $0.writer, detail: $0.detail)
        } }
        guard let state else { return }
        broadcast?(WireEnvelope.event(
            method: PhoneMethod.conversationStateMethod,
            body: JSONValue.from(ConversationStateBody(conversationId: conversationId, state: state))
        ))
    }

    func registerApproval(
        agent: AgentKind,
        conversationId: String,
        nativeSessionId: String,
        serverMethod: String,
        params: JSONValue,
        requestId: JSONValue,
        title: String,
        detail: String?
    ) {
        approvalSeq += 1
        let approvalId = "ap_\(approvalSeq)"
        var pending = LiveConversation.PendingApproval(
            serverMethod: serverMethod,
            params: params,
            agent: agent,
            nativeSessionId: nativeSessionId
        )
        pending.requestIdValue = requestId
        pending.nativeRequestId = requestId.stringValue ?? "\(approvalSeq)"
        queue.sync {
            live[conversationId]?.pendingApprovals[approvalId] = pending
            live[conversationId]?.phase = .needsApproval
        }
        emitLocal(conversationId, ConversationEvent(
            seq: 0,
            kind: .approvalRequest,
            toolName: title,
            approvalId: approvalId,
            options: ApprovalOption.phoneOptions,
            detail: detail
        ))
        caffeinate.beginTurn() // needs_approval keeps caffeinate held
        pushState(conversationId)
    }

    private func pruneClientMessageIds(_ state: inout LiveConversation) {
        let cutoff = Date().addingTimeInterval(-EventLimits.clientMessageIdTTLSeconds)
        state.clientMessageIds = state.clientMessageIds.filter { $0.value > cutoff }
        if state.clientMessageIds.count > EventLimits.clientMessageIdMemory {
            let sorted = state.clientMessageIds.sorted { $0.value < $1.value }
            for (key, _) in sorted.prefix(state.clientMessageIds.count - EventLimits.clientMessageIdMemory) {
                state.clientMessageIds.removeValue(forKey: key)
            }
        }
    }
}