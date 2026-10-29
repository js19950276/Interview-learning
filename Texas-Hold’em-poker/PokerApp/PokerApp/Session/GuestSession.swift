import Foundation
import PokerEngine

enum GuestUpdate: Sendable {
    case joined(seat: Int)
    case lobby(LobbyState)
    case snapshot(TableSnapshot)
    case disconnected
    case rejected(RejectionReason)
}

/// 客机会话：加入/行动透传/断线自动重连（spec §9）。
actor GuestSession {
    enum GuestPhase: Equatable, Sendable { case idle, joining, lobby, playing, reconnecting, ended }
    enum GuestError: Error, Sendable, Equatable {
        case joinTimedOut
        case rejected(RejectionReason)
    }

    nonisolated let updates: AsyncStream<GuestUpdate>
    private nonisolated let updatesContinuation: AsyncStream<GuestUpdate>.Continuation

    private let transport: any Transport
    private let roomID: String
    private let deviceID: String
    private let displayName: String
    private let hostPeer: PeerID
    private var phase: GuestPhase = .idle
    private var seat: Int?
    private var snapshot: TableSnapshot?
    private var lastSeq = 0
    private var seenMessageIDs: Set<String> = []
    private var processingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// 重连循环代际：只有当前代循环可写 reconnectTask——被取消/换代的旧循环
    /// 在收尾时不得清掉新循环的引用（否则 leave() 会漏杀存活循环）。
    private var reconnectGeneration = 0
    private var pendingRejection: RejectionReason?

    init(roomID: String, deviceID: String, displayName: String,
         transport: any Transport = NearbyTransport()) {
        self.roomID = roomID
        self.deviceID = deviceID
        self.displayName = displayName
        self.transport = transport
        hostPeer = PeerID(rawValue: roomID)
        (updates, updatesContinuation) = AsyncStream.makeStream(of: GuestUpdate.self)
    }

    // MARK: - 公开 API

    func join() async throws {
        guard phase == .idle else { return }
        phase = .joining
        startProcessingIfNeeded()
        do {
            try await transport.connect(to: hostPeer)
            try await sendHello()
        } catch {
            phase = .ended
            throw error
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            switch phase {
            case .lobby, .playing:
                return
            case .ended:
                throw pendingRejection.map(GuestError.rejected) ?? .joinTimedOut
            default:
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        phase = .ended
        throw GuestError.joinTimedOut
    }

    func setReady(_ value: Bool) async {
        guard phase == .lobby || phase == .playing || phase == .reconnecting else { return }
        try? await send(.ready(value))
    }

    func act(_ action: PlayerAction) async {
        guard phase == .playing else { return }
        try? await send(.action(action))
    }

    func requestNextHand() async {
        guard phase == .playing else { return }
        try? await send(.nextHand)
    }

    func leave() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        processingTask?.cancel()
        processingTask = nil
        try? await send(.bye)
        phase = .ended
        updatesContinuation.finish()
        await transport.disconnect()
    }

    /// 前台自愈：锁屏回来立即重试重连（scenePhase .active 调用）。
    nonisolated func applicationDidBecomeActive() async {
        await retryReconnectNow()
    }

    // MARK: - 测试观测

    func phaseValue() -> GuestPhase { phase }
    func seatValue() -> Int? { seat }
    func latestSnapshot() -> TableSnapshot? { snapshot }

    // MARK: - 内部

    private func sendHello() async throws {
        try await send(.hello(deviceID: deviceID, name: displayName))
    }

    private func send(_ payload: Payload) async throws {
        let sender: Sender = seat.map { .seat($0) } ?? .guest
        try await transport.send(
            try PokerWire.encode(PokerEnvelope(roomID: roomID, sender: sender, payload: payload)),
            to: hostPeer)
    }

    private func startProcessingIfNeeded() {
        guard processingTask == nil else { return }
        processingTask = Task { [weak self, transport] in
            let events = await transport.events
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: TransportEvent) async {
        switch event {
        case let .received(data, _):
            guard let envelope = try? PokerWire.decode(data) else { return }
            handleEnvelope(envelope)
        case let .disconnected(peer, _):
            guard peer == hostPeer else { return }
            if phase == .lobby || phase == .playing { beginReconnectLoop() }
        case .connected, .discovered:
            break
        }
    }

    private func handleEnvelope(_ envelope: PokerEnvelope) {
        guard envelope.roomID == roomID, envelope.sender == .host else { return }
        guard isFreshMessageID(envelope.messageID) else { return }
        switch envelope.payload {
        case let .welcome(welcomeSeat, lobby):
            seat = welcomeSeat
            phase = lobby.phase == .playing ? .playing : .lobby
            updatesContinuation.yield(.joined(seat: welcomeSeat))
            updatesContinuation.yield(.lobby(lobby))
        case let .lobby(lobby):
            if lobby.phase == .playing, phase == .lobby { phase = .playing }
            updatesContinuation.yield(.lobby(lobby))
        case let .snapshot(value):
            // seq 单调门：重连补发与在途重叠时丢弃旧帧（spec §7）
            guard value.seq > lastSeq else { return }
            lastSeq = value.seq
            snapshot = value
            if phase != .playing { phase = .playing }
            updatesContinuation.yield(.snapshot(value))
        case let .rejection(reason):
            if phase == .joining {
                pendingRejection = reason
                phase = .ended
            }
            updatesContinuation.yield(.rejected(reason))
        case .bye:
            phase = .ended
            reconnectTask?.cancel()
            reconnectTask = nil
            updatesContinuation.finish()
        default:
            break
        }
    }

    private func isFreshMessageID(_ id: String) -> Bool {
        guard !seenMessageIDs.contains(id) else { return false }
        seenMessageIDs.insert(id)
        if seenMessageIDs.count > 2048 { seenMessageIDs.removeAll() }
        return true
    }

    // MARK: - 断线自动重连（1s 起指数退避，上限 5s，无限次；用户可随时 leave）

    /// - announce: true（断线起点）置 .reconnecting 并播报 .disconnected；
    ///   false（前台重试）不重复播报——横幅已在使用方（VM）挂着。
    private func beginReconnectLoop(initialDelayNanos: UInt64 = 1_000_000_000, announce: Bool = true) {
        guard reconnectTask == nil else { return }
        reconnectGeneration += 1
        let generation = reconnectGeneration
        if announce {
            phase = .reconnecting
            updatesContinuation.yield(.disconnected)
        }
        reconnectTask = Task {
            var delay = initialDelayNanos
            while !Task.isCancelled {
                // 换代＝前台已另起循环（让位）；.ended＝宿主 bye / 用户离开（终态）——一律终止
                guard generation == reconnectGeneration, phase != .ended else { break }
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { break }
                delay = min(delay * 2, 5_000_000_000)
                guard generation == reconnectGeneration, phase != .ended else { break }
                if await transport.isConnected(to: hostPeer) { continue }
                do {
                    try await transport.connect(to: hostPeer)
                    try await sendHello()
                } catch { continue }
                // welcome 异步到达；给一小段确认窗口
                try? await Task.sleep(for: .milliseconds(300))
                if phase == .lobby || phase == .playing { break }
            }
            // 仅当前代可清引用：旧循环收尾时若已被换代，让位不清（防 clobber 新任务句柄）
            if generation == reconnectGeneration { reconnectTask = nil }
        }
    }

    private func retryReconnectNow() {
        guard reconnectTask != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        // 前台重试只清零退避、立即重拨；不重复播报 .disconnected
        beginReconnectLoop(initialDelayNanos: 0, announce: false)
    }
}
