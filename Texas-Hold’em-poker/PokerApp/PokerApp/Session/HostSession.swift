import Foundation
import PokerEngine

struct HostConfiguration: Sendable {
    var roomName: String
    var hostName: String
    /// 桌子配置；playerCount/humanSeat 在开局时按名册重建。
    var tableConfig: GameConfig
}

enum HostUpdate: Sendable {
    case lobby(LobbyState)
    case state(GameState)
}

/// 房主会话：唯一权威引擎持有者（spec §8）。
actor HostSession {
    enum HostPhase: Equatable, Sendable { case idle, lobby, playing, finished }
    enum HostError: String, Error, Sendable {
        case alreadyStarted
        case notEnoughPlayers
        case notAllReady
    }

    nonisolated let updates: AsyncStream<HostUpdate>
    private nonisolated let updatesContinuation: AsyncStream<HostUpdate>.Continuation

    private let transport: any Transport
    private var configuration: HostConfiguration
    private var phase: HostPhase = .idle
    private var roomID = ""
    private var processingTask: Task<Void, Never>?

    // 名册：座位 ↔ 身份（seat 0 恒为房主，deviceBySeat[0] = "host"）
    private var seatByPeer: [PeerID: Int] = [:]
    private var peerBySeat: [Int: PeerID] = [:]
    private var deviceBySeat: [Int: String] = [:]
    private var names: [Int: String] = [:]
    private var readySeats: Set<Int> = []
    private var state: GameState?
    private var seq = 0
    private var seenMessageIDs: Set<String> = []

    init(configuration: HostConfiguration, transport: any Transport = NearbyTransport()) {
        self.configuration = configuration
        self.transport = transport
        (updates, updatesContinuation) = AsyncStream.makeStream(of: HostUpdate.self)
    }

    // MARK: - 公开 API

    func startHosting() async throws {
        guard phase == .idle else { throw HostError.alreadyStarted }
        let suffix = String(UUID().uuidString.prefix(4)).uppercased()
        roomID = "\(RoomName.sanitize(configuration.roomName))-\(suffix)"
        names[0] = configuration.hostName.isEmpty ? "房主" : String(configuration.hostName.prefix(12))
        deviceBySeat[0] = "host"
        phase = .lobby
        try await transport.startHosting(roomID: roomID, port: nil)
        startProcessingIfNeeded()
        await publishLobby()
    }

    func setReady(_ value: Bool) async {
        guard phase == .lobby else { return }
        if value { readySeats.insert(0) } else { readySeats.remove(0) }
        await publishLobby()
    }

    func updateTableConfig(_ config: GameConfig) async {
        guard phase == .lobby else { return }
        configuration.tableConfig = config
        await publishLobby()
    }

    func startGame() async throws {
        guard phase == .lobby else { throw HostError.alreadyStarted }
        let seats = deviceBySeat.keys.sorted()
        guard seats.count >= 2 else { throw HostError.notEnoughPlayers }
        guard readySeats.isSuperset(of: seats) else { throw HostError.notAllReady }
        var config = configuration.tableConfig
        config.playerCount = seats.count
        config.humanSeat = 0
        // 注：GameState.players 对 App 模块只读（public internal(set)），无法把大厅名字写进引擎；
        // 大厅名字保留在 names[seat]，Task 8 快照/渲染时以 names[seat] 覆盖引擎默认名「座位 N」。
        let initialState = GameState.start(
            config: config,
            seed: UInt64(Date().timeIntervalSince1970 * 1000))
        state = initialState
        phase = .playing
        await publishLobby()          // phase .playing → 客机切牌桌
        await fanoutSnapshots()       // 首帧快照
    }

    /// 结束会话：停事件处理、结束更新流、断开传输（测试 tearDown 也走这里）。
    func disconnect() async {
        processingTask?.cancel()
        processingTask = nil
        updatesContinuation.finish()
        await transport.disconnect()
    }

    // MARK: - 测试观测

    func gameState() -> GameState? { state }
    func currentPhase() -> HostPhase { phase }
    func currentLobby() -> LobbyState? { phase == .idle ? nil : buildLobby() }
    func roomIDValue() -> String { roomID }
    func peerIDValue(seat: Int) -> PeerID? { peerBySeat[seat] }

    // MARK: - 传输事件处理

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
        case let .received(data, peer):
            guard let envelope = try? PokerWire.decode(data) else { return }
            await handleEnvelope(envelope, from: peer)
        case let .disconnected(peer, _):
            await handlePeerLeft(peer)
        case .connected, .discovered:
            break
        }
    }

    private func handleEnvelope(_ envelope: PokerEnvelope, from peer: PeerID) async {
        guard envelope.roomID == roomID else { return }
        guard isFreshMessageID(envelope.messageID) else { return }
        if envelope.protocolVersion != PokerProtocolVersion.current {
            try? await send(.rejection(.versionMismatch), to: peer)
            return
        }
        switch envelope.payload {
        case let .hello(deviceID, name):
            await handleHello(deviceID: deviceID, name: name, peer: peer)
        case let .ready(value):
            guard case let .seat(seat) = envelope.sender,
                  deviceBySeat[seat] != nil,
                  peerBySeat[seat] == peer,
                  phase == .lobby else { return }
            if value { readySeats.insert(seat) } else { readySeats.remove(seat) }
            await publishLobby()
        case .action, .nextHand, .bye:
            guard case let .seat(seat) = envelope.sender, peerBySeat[seat] == peer else { return }
            if case .bye = envelope.payload {
                await handlePeerLeft(peer)
                return
            }
            await handleGamePayload(envelope.payload, seat: seat)   // Task 8 实现；本任务先留空方法
        default:
            break
        }
    }

    /// Task 8 填充对局逻辑；本任务先做空实现保证编译。
    private func handleGamePayload(_ payload: Payload, seat: Int) async {}

    private func handleHello(deviceID: String, name: String, peer: PeerID) async {
        // "host" 是房主保留 deviceID；空 ID 视为畸形 hello，一律忽略
        guard !deviceID.isEmpty, deviceID != "host" else { return }
        // 已绑定连接重复 hello：重发 welcome 即可（幂等）
        if let bound = seatByPeer[peer] {
            try? await send(.welcome(seat: bound, lobby: buildLobby()), to: peer)
            return
        }
        // 一条连接只能绑一个 deviceID；同 deviceID 新连接 = 接管旧连接
        if let existingPeer = (deviceBySeat.first(where: { $0.value == deviceID })?.key)
            .flatMap({ seat -> PeerID? in peerBySeat[seat] }),
           existingPeer != peer {
            seatByPeer.removeValue(forKey: existingPeer)
        }
        // 重连：已知 deviceID 还原原座位
        if let seat = deviceBySeat.first(where: { $0.value == deviceID })?.key {
            bind(peer: peer, seat: seat)
            try? await send(.welcome(seat: seat, lobby: buildLobby()), to: peer)
            if phase == .playing || phase == .finished {
                await resendCurrentSnapshots()   // 补发当前快照：seq 不前进，已收过的客机按 seq 门丢弃，错过的补齐
            } else {
                await publishLobby()
            }
            return
        }
        // 新面孔
        guard phase == .lobby else {
            try? await send(.rejection(.gameStarted), to: peer)
            return
        }
        let taken = Set(deviceBySeat.keys)
        guard let seat = (0..<9).first(where: { !taken.contains($0) }) else {
            try? await send(.rejection(.roomFull), to: peer)
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        deviceBySeat[seat] = deviceID
        names[seat] = trimmed.isEmpty ? "玩家-\(String(deviceID.suffix(4)))" : String(trimmed.prefix(12))
        bind(peer: peer, seat: seat)
        try? await send(.welcome(seat: seat, lobby: buildLobby()), to: peer)
        await publishLobby()
    }

    private func handlePeerLeft(_ peer: PeerID) async {
        guard let seat = seatByPeer[peer] else { return }
        seatByPeer.removeValue(forKey: peer)
        peerBySeat[seat] = nil
        if phase == .lobby {
            // 大厅期离开：座位彻底释放
            deviceBySeat[seat] = nil
            names[seat] = nil
            readySeats.remove(seat)
        }
        // 对局期：deviceBySeat 保留（可重连），座位标记为断线（Task 8 托管用）
        await publishLobby()
        await reconcileDisconnectedActor()   // Task 8 实现；本任务空方法
    }

    private func bind(peer: PeerID, seat: Int) {
        seatByPeer[peer] = seat
        peerBySeat[seat] = peer
    }

    /// Task 8 填充；本任务空实现保证编译。
    private func reconcileDisconnectedActor() async {}

    private func isFreshMessageID(_ id: String) -> Bool {
        guard !seenMessageIDs.contains(id) else { return false }
        seenMessageIDs.insert(id)
        if seenMessageIDs.count > 2048 { seenMessageIDs.removeAll() }
        return true
    }

    // MARK: - 广播

    private func buildLobby() -> LobbyState {
        let players = deviceBySeat.keys.sorted().map { seat in
            LobbyPlayer(seat: seat,
                        name: names[seat] ?? "座位 \(seat + 1)",
                        isHost: seat == 0,
                        ready: readySeats.contains(seat),
                        connected: seat == 0 || peerBySeat[seat] != nil)
        }
        return LobbyState(
            phase: (phase == .playing || phase == .finished) ? .playing : .lobby,
            roomName: configuration.roomName,
            players: players,
            config: configuration.tableConfig)
    }

    private func publishLobby() async {
        let lobby = buildLobby()
        updatesContinuation.yield(.lobby(lobby))
        for (_, peer) in peerBySeat {
            try? await send(.lobby(lobby), to: peer)
        }
    }

    /// Task 8 填充；本任务空实现保证编译。
    private func fanoutSnapshots() async {}
    private func resendCurrentSnapshots() async {}

    private func send(_ payload: Payload, to peer: PeerID) async throws {
        try await transport.send(
            try PokerWire.encode(PokerEnvelope(roomID: roomID, sender: .host, payload: payload)),
            to: peer)
    }
}
