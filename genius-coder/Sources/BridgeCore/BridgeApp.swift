import Foundation
import PhoneProtocol

/// Wires the phone API surface (projects/conversations/open/send/...) onto
/// the index and the conversation manager. One instance lives for the app
/// lifetime behind the menu bar (or the CLI smoke commands).
public final class BridgeApp: @unchecked Sendable {
    public let appSupport: URL
    public let indexStore: IndexStore
    public let conversations: ConversationManager
    public let server: BridgeServer
    public let caffeinate = Caffeinate()
    private let processGroups: ProcessGroups
    /// Layer ②: embedded userspace Tailscale (nil-host when not configured).
    public let tsnet: TsnetSupervisor?

    public init(appSupport: URL? = nil, indexers: [AgentIndexer]? = nil) {
        let support = appSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("genius-coder")
        self.appSupport = support
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let binaries = AgentBinaries()
        var allowlist = Allowlist.load(from: support)
        // One-shot seeding prompt state machine (spec: Indexer → 允许列表).
        if !allowlist.seedPromptAnswered {
            let seeder = AllowlistSeeder()
            let scratch = IndexStore(appSupportDirectory: support.appendingPathComponent("seed-scratch"), allowlist: Allowlist(roots: [], allowRoot: true))
            scratch.refresh()
            let roots = seeder.candidateRoots(from: scratch.knownCwds())
            // The menu bar shows the prompt; until a human answers it, keep
            // the allowlist untouched-but-armed so the UI can render both
            // options. See BridgeMenuBarView.
            _ = roots
            allowlist.seedPromptAnswered = false
        }
        self.indexStore = IndexStore(
            appSupportDirectory: support,
            allowlist: allowlist,
            indexers: indexers ?? [CodexIndex(), GrokIndex(), ClaudeIndex(), DshIndex()]
        )
        self.conversations = ConversationManager(indexStore: indexStore, binaries: binaries, appSupport: support)
        self.server = BridgeServer(appSupportDirectory: support)
        self.processGroups = ProcessGroups(directory: support)
        let supervisor = TsnetSupervisor(bridgePort: 8787)
        self.tsnet = supervisor.isConfigured ? supervisor : nil
        self.indexStore.refresh()
        // Reap crashed-leftover child process groups before serving anything.
        processGroups.reapOrphans(from: support)
        server.apiHandler = { [weak self] session, method, body, completion in
            self?.handle(session: session, method: method, body: body, completion: completion)
        }
        conversations.broadcast = { [weak self] envelope in
            self?.server.allSessions().forEach { $0.send(envelope) }
        }
    }

    @discardableResult
    public func startNetwork() -> UInt16? {
        let port = server.start()
        if let port, let tsnet {
            Task.detached { [weak self] in
                guard let self else { return }
                let status = await tsnet.start()
                if let host = status.hostEntry {
                    self.server.extraQRHosts.append(host)
                }
            }
        }
        return port
    }

    public func stop() {
        tsnet?.stop()
        server.stop()
        conversations.dsh?.stop()
        conversations.codex?.stop()
    }

    // MARK: API routing

    func handle(
        session: PhoneSession,
        method: String,
        body: JSONValue?,
        completion: @escaping (Result<JSONValue?, PhoneErrorCode>) -> Void
    ) {
        switch method {
        case PhoneMethod.ping.rawValue:
            completion(.success(JSONValue.from(PingResponse(
                bridgeId: server.pairingStore.bridgeId,
                serverTime: Int64(Date().timeIntervalSince1970 * 1000)
            ))))
        case PhoneMethod.projectsList.rawValue:
            let filter = (body.flatMap { try? $0.asDecode(ProjectsListRequest.self) })?.agent ?? .all
            let projects = indexStore.projects(filter: filter)
            completion(.success(JSONValue.from(ProjectsListResponse(
                projects: projects,
                indexedAt: indexStore.currentIndexedAt
            ))))
        case PhoneMethod.conversationsList.rawValue:
            guard let request = body.flatMap({ try? $0.asDecode(ConversationsListRequest.self) }) else {
                completion(.failure(.malformedRequest))
                return
            }
            let conversations = indexStore.conversations(
                projectId: request.projectId,
                filter: request.agent ?? .all,
                limit: request.limit ?? 100
            )
            completion(.success(JSONValue.from(ConversationsListResponse(conversations: conversations))))
        case PhoneMethod.conversationOpen.rawValue:
            guard let request = body.flatMap({ try? $0.asDecode(ConversationOpenRequest.self) }) else {
                completion(.failure(.malformedRequest))
                return
            }
            switch conversations.open(conversationId: request.conversationId) {
            case .success(let response):
                completion(.success(JSONValue.from(response)))
            case .failure(let code):
                completion(.failure(code))
            }
        case PhoneMethod.conversationHistory.rawValue:
            guard let request = body.flatMap({ try? $0.asDecode(ConversationHistoryRequest.self) }) else {
                completion(.failure(.malformedRequest))
                return
            }
            switch conversations.history(conversationId: request.conversationId, cursor: request.cursor) {
            case .success(let response):
                completion(.success(JSONValue.from(response)))
            case .failure(let code):
                completion(.failure(code))
            }
        case PhoneMethod.conversationSend.rawValue:
            guard let request = body.flatMap({ try? $0.asDecode(ConversationSendRequest.self) }),
                  !request.text.isEmpty else {
                completion(.failure(.malformedRequest))
                return
            }
            switch conversations.send(conversationId: request.conversationId, clientMessageId: request.clientMessageId, text: request.text) {
            case .success:
                completion(.success(.object([:])))
            case .failure(let code):
                completion(.failure(code))
            }
        case PhoneMethod.conversationCancel.rawValue:
            guard let request = body.flatMap({ try? $0.asDecode(ConversationCancelRequest.self) }) else {
                completion(.failure(.malformedRequest))
                return
            }
            switch conversations.cancel(conversationId: request.conversationId) {
            case .success:
                completion(.success(.object([:])))
            case .failure(let code):
                completion(.failure(code))
            }
        case PhoneMethod.conversationApproval.rawValue:
            guard let request = body.flatMap({ try? $0.asDecode(ConversationApprovalRequest.self) }) else {
                completion(.failure(.malformedRequest))
                return
            }
            switch conversations.approve(conversationId: request.conversationId, approvalId: request.approvalId, optionId: request.optionId) {
            case .success:
                completion(.success(.object([:])))
            case .failure(let code):
                completion(.failure(code))
            }
        default:
            completion(.failure(.unsupportedMethod))
        }
    }
}
