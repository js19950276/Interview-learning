import SwiftUI
import UIKit
import CryptoKit
import Security
import PhoneProtocol
import GeniusTsnet


// MARK: - Connection labels

enum ConnectionKind: String, Codable {
    case lan
    case tailscale
}

enum ConnectionLabel: String {
    case lan = "LAN"
    case tailscale = "Tailscale"
    case disconnected = "断开"
}

// MARK: - Paired configuration persisted in the Keychain

struct PairedConfig: Codable, Equatable {
    /// Ed25519 private key raw representation (Curve25519.Signing.PrivateKey).
    var privateKeyRaw: Data
    var bridgeId: String
    var certificateFingerprint: String
    var host: String
    var hostKind: String
    var lanHost: String?
    var tailscaleHost: String?
    var port: UInt16
    var deviceId: String

    var signingKey: Curve25519.Signing.PrivateKey? {
        try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
    }

    /// Tailscale IPv4 is 100.64.0.0/10; Tailscale IPv6 is fd7a:115c:a1e0::/48.
    static func classifyHost(_ host: String) -> ConnectionKind {
        let lowered = host.lowercased()
        if lowered.hasPrefix("fd7a:115c:a1e0:") {
            return .tailscale
        }
        let parts = lowered.split(separator: ".").compactMap { UInt32($0) }
        if parts.count == 4, parts.allSatisfy({ $0 <= 255 }) {
            let address = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
            if address >= 0x64400000 && address <= 0x647FFFFF {
                return .tailscale
            }
        }
        return .lan
    }
}

// MARK: - Keychain store (this device only, never synced)

struct KeychainStore {
    let service = "com.local.geniuscoder.phone"
    let account = "pairing"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    func save(_ config: PairedConfig) throws {
        let data = try JSONEncoder().encode(config)
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain 写入失败 (\(status))"]
            )
        }
    }

    func load() -> PairedConfig? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let config = try? JSONDecoder().decode(PairedConfig.self, from: data) else {
            return nil
        }
        return config
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - Local JSON cache (Application Support, excluded from backup)

final class PhoneCache {
    struct Store: Codable {
        var projects: [ProjectSummary] = []
        var indexedAt: Int64 = 0
        var conversationsByProject: [String: [ConversationSummary]] = [:]
        var eventsByConversation: [String: [ConversationEvent]] = [:]
    }

    private(set) var store = Store()
    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "com.local.geniuscoder.phone.cache", qos: .utility)

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("genius-coder-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (dir as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        fileURL = dir.appendingPathComponent("store.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Store.self, from: data) else {
            return
        }
        store = decoded
    }

    func mutate(_ change: (inout Store) -> Void) {
        change(&store)
        let snapshot = store
        let url = fileURL
        writeQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func clear() {
        store = Store()
        let url = fileURL
        writeQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - UI state models

enum PairingStep: Equatable {
    case idle
    case working(String)
    case failed(String)
    case done
}

struct PendingApproval: Identifiable, Equatable {
    var approvalId: String
    var options: [ApprovalOption]
    var id: String { approvalId }
}

struct OpenSession: Equatable {
    var conversationId: String
    var summary: ConversationSummary?
    var sessionState: SessionState
    var events: [ConversationEvent]
    var olderCursor: String?
    var nextSeq: Int64
    var approval: PendingApproval?
    /// Machine-ish notice such as `empty_history` or `offline`.
    var openNotice: String?
}

// MARK: - AppModel

@MainActor
final class AppModel: ObservableObject {

    @Published var unlocked = false
    @Published var requireFaceID: Bool {
        didSet { UserDefaults.standard.set(requireFaceID, forKey: Self.requireFaceIDKey) }
    }
    @Published var connection: ConnectionLabel = .disconnected
    @Published var connectionDetail: String?
    @Published var projects: [ProjectSummary] = []
    @Published var agentFilter: AgentFilter = .all {
        didSet { Task { await refreshProjects() } }
    }
    @Published var refreshingProjects = false
    @Published var loadingConversations = false
    @Published var conversations: [ConversationSummary] = []
    @Published var openSession: OpenSession?
    @Published var paired: PairedConfig?
    @Published var pairingStep: PairingStep = .idle
    @Published var banner: String?
    /// Set when the embedded tailnet needs an interactive login; shown as
    /// a link the user taps once (SFSafariViewController / openURL).
    @Published var tsnetLoginURL: URL?

    let client = BridgePhoneClient()
    private let keychain = KeychainStore()
    private let cache = PhoneCache()
    let deviceId: String
    private var reconnectTask: Task<Void, Never>?
    private var reconnecting = false

    static let requireFaceIDKey = "requireFaceID"
    private static let deviceIdKey = "deviceId"

    init() {
        let defaults = UserDefaults.standard
        requireFaceID = defaults.object(forKey: Self.requireFaceIDKey) as? Bool ?? true
        if let existing = defaults.string(forKey: Self.deviceIdKey) {
            deviceId = existing
        } else {
            let fresh = Self.randomDeviceId()
            defaults.set(fresh, forKey: Self.deviceIdKey)
            deviceId = fresh
        }
        paired = keychain.load()
        client.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleTransportState(state) }
        }
        client.onEvent = { [weak self] envelope in
            Task { @MainActor in self?.handleWireEvent(envelope) }
        }
    }

    private static func randomDeviceId() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 4, buffer.baseAddress!)
        }
        return "dev_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    var deviceName: String { UIDevice.current.name }

    // MARK: Unlock — Face ID must pass BEFORE the local cache is read

    func unlockAndStart() {
        guard !unlocked else { return }
        unlocked = true
        cache.load()
        projects = cache.store.projects
        if paired != nil {
            Task { await reconnect() }
        }
    }

    // MARK: Derived state

    var isConnected: Bool { client.state() == .connected }

    var visibleProjects: [ProjectSummary] {
        guard let agent = agentFilter.agent else { return projects }
        return projects.filter { ($0.counts[agent.rawValue] ?? 0) > 0 }
    }

    private var duplicateDisplayNames: Set<String> {
        var counts: [String: Int] = [:]
        for project in projects {
            counts[project.displayName, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    func displayTitle(for project: ProjectSummary) -> String {
        if duplicateDisplayNames.contains(project.displayName) {
            let parts = project.canonicalPath.split(separator: "/").map(String.init)
            if parts.count >= 2 {
                return "\(parts[parts.count - 2])/\(project.displayName)"
            }
        }
        return project.displayName
    }

    var topLevelConversations: [ConversationSummary] {
        conversations
            .filter { $0.parentConversationId == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func childConversations(of parentId: String) -> [ConversationSummary] {
        conversations
            .filter { $0.parentConversationId == parentId }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Composer is enabled only in `idle`, with no pending approval and a live connection.
    var composerEnabled: Bool {
        guard let session = openSession else { return false }
        guard session.approval == nil else { return false }
        guard session.sessionState.phase == .idle else { return false }
        guard session.sessionState.connection == .connected else { return false }
        return isConnected
    }

    // MARK: Connection / reconnect (last host 2s, then Tailscale fallback)

    func reconnect() async {
        guard paired != nil, !reconnecting else { return }
        guard client.state() != .connected else { return }
        reconnecting = true
        defer { reconnecting = false }

        guard let config = paired else { return }
        var candidates: [(host: String, kind: ConnectionKind)] = []
        candidates.append((config.host, ConnectionKind(rawValue: config.hostKind) ?? .lan))
        if let tailscale = config.tailscaleHost, tailscale != config.host {
            candidates.append((tailscale, .tailscale))
        }
        if let lan = config.lanHost, lan != config.host, !candidates.contains(where: { $0.host == lan }) {
            candidates.append((lan, .lan))
        }

        connectionDetail = "连接中…"
        for (index, candidate) in candidates.enumerated() {
            let timeout: TimeInterval = index == 0 ? 2.0 : 8.0
            if await tryHost(candidate.host, kind: candidate.kind, port: config.port, timeout: timeout) {
                reconnectTask?.cancel()
                reconnectTask = nil
                await refreshProjects()
                return
            }
        }
        connection = .disconnected
        connectionDetail = "LAN 与 Tailscale 都连不上"
        scheduleReconnect()
    }

    private func tryHost(
        _ host: String,
        kind: ConnectionKind,
        port: UInt16,
        timeout: TimeInterval
    ) async -> Bool {
        guard let config = paired,
              let key = config.signingKey else { return false }

        // Layer ②: tailscale addresses go through the in-app userspace
        // stack (tsnet) via a loopback proxy — no Tailscale app needed.
        var dialHost = host
        var dialPort = port
        if kind == .tailscale {
            switch await ensureTsnetProxy(to: host, port: port) {
            case .success(let proxyPort):
                dialHost = "127.0.0.1"
                dialPort = proxyPort
            case .failure(let reason):
                connectionDetail = "tsnet: \(reason)"
                return false
            }
        }

        let configuration = BridgePhoneClient.Configuration(
            host: dialHost,
            port: dialPort,
            certificateFingerprint: config.certificateFingerprint,
            bridgeId: config.bridgeId,
            deviceId: config.deviceId,
            signingKey: key
        )
        client.disconnect()
        client.connect(configuration: configuration)
        guard await waitConnected(timeout: timeout) else {
            client.disconnect()
            return false
        }
        let authenticated = await client.authenticate()
        guard authenticated else {
            client.disconnect()
            return false
        }
        connection = kind == .tailscale ? .tailscale : .lan
        connectionDetail = "\(host):\(port)"
        if config.host != host || config.hostKind != kind.rawValue {
            var updated = config
            updated.host = host
            updated.hostKind = kind.rawValue
            paired = updated
            try? keychain.save(updated)
        }
        return true
    }

    private enum TsnetOutcome {
        case success(UInt16)
        case failure(String)
    }

    /// Join the tailnet (first run needs an interactive login URL shown in
    /// the UI) and open a loopback proxy to the bridge.
    private func ensureTsnetProxy(to host: String, port: UInt16) async -> TsnetOutcome {
        let state = PhoneTsnet.status()
        if !state.hasPrefix("ready:") {
            if state == "idle" {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("tsnet").path
                let result = await Task.detached {
                    await PhoneTsnet.start(authKey: "", hostname: "genius-coder-phone", stateDir: support)
                }.value
                if result.hasPrefix("needs-login:"), let url = URL(string: String(result.dropFirst("needs-login:".count))) {
                    await MainActor.run {
                        tsnetLoginURL = url
                    }
                    return .failure("需要登录 Tailscale")
                }
                if !result.hasPrefix("ready:") {
                    return .failure(result == "timeout" ? "tsnet 超时" : result)
                }
            } else if state.hasPrefix("needs-login:") {
                let url = String(state.dropFirst("needs-login:".count))
                if !url.isEmpty, let parsed = URL(string: url) {
                    await MainActor.run { tsnetLoginURL = parsed }
                }
                return .failure("需要登录 Tailscale")
            }
        }
        guard let proxyPort = PhoneTsnet.startProxy(destination: "\(host):\(port)") else {
            return .failure("代理启动失败")
        }
        return .success(proxyPort)
    }

    private func waitConnected(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if client.state() == .connected { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return client.state() == .connected
    }

    private func scheduleReconnect() {
        guard paired != nil, reconnectTask == nil, !reconnecting else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            if self.client.state() != .connected {
                await self.reconnect()
            }
        }
    }

    // MARK: Transport callbacks

    private func handleTransportState(_ state: BridgePhoneClient.ClientState) {
        switch state {
        case .idle:
            break
        case .connecting:
            if connectionDetail == nil { connectionDetail = "连接中…" }
        case .connected:
            if connection == .disconnected { connectionDetail = "已连接，正在认证…" }
        case .disconnected(let reason):
            connection = .disconnected
            connectionDetail = reason
            if var session = openSession {
                session.sessionState.connection = .disconnected
                openSession = session
            }
            scheduleReconnect()
        }
    }

    // MARK: Wire events

    private func handleWireEvent(_ envelope: WireEnvelope) {
        guard let method = envelope.method, let body = envelope.body else { return }
        if method == PhoneMethod.conversationEventMethod {
            guard let decoded = try? body.asDecode(ConversationEventBody.self) else { return }
            applyEvent(decoded.conversationId, decoded.event)
        } else if method == PhoneMethod.conversationStateMethod {
            guard let decoded = try? body.asDecode(ConversationStateBody.self) else { return }
            applyState(decoded.conversationId, decoded.state)
        } else if method == PhoneMethod.conversationSnapshot.rawValue {
            guard let decoded = try? body.asDecode(ConversationSnapshotBody.self) else { return }
            applySnapshot(decoded)
        }
    }

    private func applyEvent(_ conversationId: String, _ event: ConversationEvent) {
        cache.mutate { store in
            store.eventsByConversation[conversationId] = Self.mergeEvents(
                old: store.eventsByConversation[conversationId] ?? [],
                new: [event]
            )
        }
        guard var session = openSession, session.conversationId == conversationId else { return }
        session.events = Self.mergeEvents(old: session.events, new: [event])
        switch event.kind {
        case .approvalRequest:
            if let approvalId = event.approvalId {
                session.approval = PendingApproval(
                    approvalId: approvalId,
                    options: event.options ?? ApprovalOption.phoneOptions
                )
                session.sessionState.phase = .needsApproval
            }
        case .approvalResolved:
            session.approval = nil
        default:
            break
        }
        openSession = session
    }

    private func applyState(_ conversationId: String, _ state: SessionState) {
        guard var session = openSession, session.conversationId == conversationId else { return }
        session.sessionState = state
        if session.approval != nil,
           state.phase != .needsApproval,
           state.phase != .streaming {
            session.approval = nil
        }
        openSession = session
    }

    private func applySnapshot(_ body: ConversationSnapshotBody) {
        cache.mutate { store in
            store.eventsByConversation[body.conversationId] = body.events
        }
        guard var session = openSession, session.conversationId == body.conversationId else { return }
        session.events = body.events
        session.nextSeq = body.nextSeq
        openSession = session
    }

    static func mergeEvents(old: [ConversationEvent], new: [ConversationEvent]) -> [ConversationEvent] {
        var bySeq = Dictionary(uniqueKeysWithValues: old.map { ($0.seq, $0) })
        for event in new {
            bySeq[event.seq] = event
        }
        return bySeq.values.sorted { $0.seq < $1.seq }
    }

    // MARK: projects.list

    func refreshProjects() async {
        guard client.state() == .connected else { return }
        refreshingProjects = true
        defer { refreshingProjects = false }
        let body = JSONValue.from(ProjectsListRequest(agent: agentFilter))
        let response = await client.request(PhoneMethod.projectsList.rawValue, body: body)
        if response.type == .res, response.ok == true, let payload = response.body,
           let decoded = try? payload.asDecode(ProjectsListResponse.self) {
            projects = decoded.projects
            cache.mutate { store in
                store.projects = decoded.projects
                store.indexedAt = decoded.indexedAt
            }
        } else if response.type == .err {
            banner = response.message ?? response.code ?? "项目列表拉取失败"
        }
    }

    // MARK: conversations.list

    func loadConversations(projectId: String) async {
        if let cached = cache.store.conversationsByProject[projectId] {
            conversations = cached
        } else {
            conversations = []
        }
        guard client.state() == .connected else { return }
        loadingConversations = true
        defer { loadingConversations = false }
        let body = JSONValue.from(ConversationsListRequest(projectId: projectId, agent: agentFilter))
        let response = await client.request(PhoneMethod.conversationsList.rawValue, body: body)
        if response.type == .res, response.ok == true, let payload = response.body,
           let decoded = try? payload.asDecode(ConversationsListResponse.self) {
            conversations = decoded.conversations
            cache.mutate { store in
                store.conversationsByProject[projectId] = decoded.conversations
            }
        } else if response.type == .err {
            banner = response.message ?? response.code ?? "会话列表拉取失败"
        }
    }

    // MARK: conversation.open / history

    func openConversation(_ conversationId: String) async {
        var summary = conversations.first { $0.conversationId == conversationId }
        if summary == nil {
            summary = cache.store.conversationsByProject.values.flatMap { $0 }
                .first { $0.conversationId == conversationId }
        }
        var session = OpenSession(
            conversationId: conversationId,
            summary: summary,
            sessionState: SessionState(
                phase: .idle,
                connection: .disconnected,
                writer: .unknown
            ),
            events: cache.store.eventsByConversation[conversationId] ?? [],
            olderCursor: nil,
            nextSeq: 0,
            approval: nil,
            openNotice: nil
        )
        guard client.state() == .connected else {
            session.openNotice = "offline"
            openSession = session
            return
        }
        let body = JSONValue.from(ConversationOpenRequest(conversationId: conversationId))
        let response = await client.request(PhoneMethod.conversationOpen.rawValue, body: body)
        if response.type == .res, response.ok == true, let payload = response.body,
           let decoded = try? payload.asDecode(ConversationOpenResponse.self) {
            session.summary = decoded.conversation
            session.sessionState = decoded.state
            session.events = Self.mergeEvents(old: session.events, new: decoded.events)
            session.nextSeq = decoded.nextSeq
            session.olderCursor = decoded.olderCursor
            if decoded.conversation.resumable == false, session.sessionState.phase == .idle {
                session.sessionState.phase = .unavailable
            }
            openSession = session
            cache.mutate { store in
                store.eventsByConversation[conversationId] = session.events
            }
        } else if response.type == .err {
            session.openNotice = response.code ?? response.message ?? "open_failed"
            if session.events.isEmpty {
                session.sessionState = SessionState(
                    phase: .unavailable,
                    connection: .connected,
                    writer: .none,
                    detail: response.code
                )
            }
            openSession = session
        }
    }

    func loadOlder() async {
        guard var session = openSession, let cursor = session.olderCursor else { return }
        let body = JSONValue.from(ConversationHistoryRequest(
            conversationId: session.conversationId,
            cursor: cursor
        ))
        let response = await client.request(PhoneMethod.conversationHistory.rawValue, body: body)
        if response.type == .res, response.ok == true, let payload = response.body,
           let decoded = try? payload.asDecode(ConversationHistoryResponse.self) {
            session.events = Self.mergeEvents(old: decoded.events, new: session.events)
            session.olderCursor = decoded.olderCursor
            openSession = session
            cache.mutate { store in
                store.eventsByConversation[session.conversationId] = session.events
            }
        } else if response.type == .err {
            banner = response.message ?? response.code ?? "历史加载失败"
        }
    }

    // MARK: conversation.send / cancel / approval

    func send(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, composerEnabled, var session = openSession else { return }
        let clientMessageId = "cm_" + UUID().uuidString
        let body = JSONValue.from(ConversationSendRequest(
            conversationId: session.conversationId,
            clientMessageId: clientMessageId,
            text: trimmed
        ))
        let response = await client.request(PhoneMethod.conversationSend.rawValue, body: body)
        if response.type == .res, response.ok == true {
            session.sessionState.phase = .streaming
            session.sessionState.writer = .bridge
            openSession = session
        } else {
            banner = response.message ?? response.code ?? "发送失败"
        }
    }

    func cancel() async {
        guard var session = openSession else { return }
        let body = JSONValue.from(ConversationCancelRequest(conversationId: session.conversationId))
        let response = await client.request(PhoneMethod.conversationCancel.rawValue, body: body)
        if response.type == .res, response.ok == true {
            session.sessionState.phase = .idle
            session.sessionState.writer = .none
            session.approval = nil
            openSession = session
        } else {
            banner = response.message ?? response.code ?? "取消失败"
        }
    }

    func approve(optionId: String) async {
        guard var session = openSession,
              let approval = session.approval,
              ApprovalOption.isValid(optionId) else { return }
        let body = JSONValue.from(ConversationApprovalRequest(
            conversationId: session.conversationId,
            approvalId: approval.approvalId,
            optionId: optionId
        ))
        session.approval = nil
        openSession = session
        let response = await client.request(PhoneMethod.conversationApproval.rawValue, body: body)
        if response.type != .res || response.ok != true {
            banner = response.message ?? response.code ?? "批准发送失败"
        }
    }

    // MARK: Pairing

    func pair(scannedQR payload: PairingQRPayload) async {
        if case .working = pairingStep { return }
        pairingStep = .working("正在连接 bridge…")

        var candidates: [PairingQRPayload.Host] = []
        candidates += payload.hosts.filter { $0.kind == "lan" }
        candidates += payload.hosts.filter { $0.kind == "tailscale" }
        candidates += payload.hosts.filter { $0.kind != "lan" && $0.kind != "tailscale" }
        guard !candidates.isEmpty else {
            pairingStep = .failed("二维码里没有可用地址")
            return
        }

        for (index, candidate) in candidates.enumerated() {
            let configuration = BridgePhoneClient.Configuration(
                host: candidate.address,
                port: payload.port,
                certificateFingerprint: payload.fp,
                bridgeId: payload.bridgeId,
                deviceId: deviceId,
                signingKey: Curve25519.Signing.PrivateKey()
            )
            client.disconnect()
            client.connect(configuration: configuration)
            pairingStep = .working("正在连接 \(candidate.address)…")
            let timeout: TimeInterval = index == 0 ? 5.0 : 8.0
            guard await waitConnected(timeout: timeout) else {
                client.disconnect()
                continue
            }
            pairingStep = .working("正在配对…")
            let result = await client.enroll(scanned: payload, deviceId: deviceId, name: deviceName)
            switch result {
            case .success(let enrolled):
                let config = PairedConfig(
                    privateKeyRaw: enrolled.signingKey.rawRepresentation,
                    bridgeId: enrolled.bridgeId,
                    certificateFingerprint: enrolled.certificateFingerprint,
                    host: candidate.address,
                    hostKind: (candidate.kind == "tailscale" ? ConnectionKind.tailscale : .lan).rawValue,
                    lanHost: payload.hosts.first(where: { $0.kind == "lan" })?.address,
                    tailscaleHost: payload.hosts.first(where: { $0.kind == "tailscale" })?.address,
                    port: payload.port,
                    deviceId: deviceId
                )
                do {
                    try keychain.save(config)
                } catch {
                    pairingStep = .failed(error.localizedDescription)
                    return
                }
                paired = config
                let kind = candidate.kind == "tailscale" ? ConnectionKind.tailscale : .lan
                connection = kind == .tailscale ? .tailscale : .lan
                connectionDetail = "\(candidate.address):\(payload.port)"
                pairingStep = .done
                await refreshProjects()
                return
            case .failure(let code):
                pairingStep = .failed(Self.pairingMessage(for: code))
                return
            }
        }
        pairingStep = .failed("无法连接 bridge（LAN 与 Tailscale 都失败了）")
    }

    private static func pairingMessage(for code: PhoneErrorCode) -> String {
        switch code {
        case .pairingRejected:
            return "配对被拒绝：token 可能已过期，请在 Mac 上重新生成二维码"
        case .unauthenticated:
            return "认证失败，请重新配对"
        case .unsupportedProtocol:
            return "协议版本不受支持，请升级两端的 genius-coder"
        case .malformedRequest:
            return "bridge 返回的数据格式不正确"
        case .internalError:
            return "bridge 内部错误，请重试"
        default:
            return "配对失败：\(code.rawValue)"
        }
    }

    // MARK: Settings actions

    func applyManualHost(host: String, port: UInt16) async {
        guard var config = paired else { return }
        config.host = host
        config.port = port
        config.hostKind = PairedConfig.classifyHost(host).rawValue
        do {
            try keychain.save(config)
        } catch {
            banner = error.localizedDescription
            return
        }
        paired = config
        await reconnect()
    }

    func forgetDevice() {
        reconnectTask?.cancel()
        reconnectTask = nil
        keychain.delete()
        client.disconnect()
        paired = nil
        projects = []
        conversations = []
        openSession = nil
        connection = .disconnected
        connectionDetail = nil
        pairingStep = .idle
    }

    func clearCache() {
        cache.clear()
        projects = []
        conversations = []
        openSession = nil
    }
}
