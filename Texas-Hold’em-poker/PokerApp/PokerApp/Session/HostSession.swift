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
        // 昵称经引擎写入口落地（players 对 App 只读）：房主直读引擎与客机快照同源（T8）。
        var initialState = GameState.start(
            config: config,
            seed: UInt64(Date().timeIntervalSince1970 * 1000))
        for seat in seats {
            initialState.renamePlayer(seat: seat, to: names[seat] ?? "座位 \(seat + 1)")
        }
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

    // MARK: - 对局阶段公开 API（Task 8）

    /// 房主自己（seat 0）的行动入口；与客机意图走同一校验与扇出路径。
    func act(_ action: PlayerAction) async {
        await applyAction(action, seat: 0)
    }

    /// 房主请求下一手（与客机请求等价，引擎幂等只放行一次）。
    func requestNextHand() async {
        await handleNextHand()
    }

    /// 前台自愈：App 挂起可能无声杀死监听 socket（scenePhase .active 调用）。
    nonisolated func applicationDidBecomeActive() async {
        await transport.reviveHostingIfNeeded()
    }

    // MARK: - 对局内消息与状态推进

    private func handleGamePayload(_ payload: Payload, seat: Int) async {
        guard phase == .playing, state != nil else { return }
        switch payload {
        case let .action(action):
            await applyAction(action, seat: seat)
        case .nextHand:
            await handleNextHand()
        default:
            break
        }
    }

    private func applyAction(_ action: PlayerAction, seat: Int) async {
        guard phase == .playing, var current = state, let actor = current.actorSeat else { return }
        guard actor == seat else {
            try? await sendToSeat(seat, .rejection(.notYourTurn))
            return
        }
        // 网络输入必须先过合法性门：引擎对非法动作按弃牌处理、对非法加注有 precondition
        // 崩溃路径，绝不能让未校验的动作直达引擎（spec §8）。
        let legal = legalActions(current)
        guard isLegal(action, in: legal) else {
            try? await sendToSeat(seat, .rejection(.illegalAction))
            return
        }
        current.apply(action)
        state = current
        await afterEngineChange()
    }

    private func handleNextHand() async {
        guard phase == .playing, let current = state,
              current.street == .handOver, !current.tournamentOver else { return }
        var next = current
        next.nextHand()
        state = next
        await afterEngineChange()
    }

    /// 引擎变更后的统一后处理：托管断线者 → 扇出快照 → 通知房主 UI。
    private func afterEngineChange() async {
        if state?.tournamentOver == true { phase = .finished }
        await reconcileDisconnectedActor()
        await fanoutSnapshots()
        if let state { updatesContinuation.yield(.state(state)) }
    }

    /// 断线座位轮到时自动「能过则过、否则弃牌」（spec §2 决策）；12 次 > 9 座上限，防死循环。
    private func reconcileDisconnectedActor() async {
        var iterations = 0
        while iterations < 12,
              var current = state,
              let actor = current.actorSeat,
              actor != 0,
              peerBySeat[actor] == nil,
              [.preflop, .flop, .turn, .river].contains(current.street) {
            let legal = legalActions(current)
            current.apply(legal.canCheck ? .check : .fold)
            state = current
            iterations += 1
        }
        if state?.tournamentOver == true { phase = .finished }
    }

    /// 每个在线座位生成 recipient 专属脱敏快照逐个发送；seq 单调；失败不阻塞其他座位。
    private func fanoutSnapshots() async {
        guard let current = state else { return }
        seq += 1
        for (seat, peer) in peerBySeat where seat != 0 {
            let snapshot = TableSnapshot.make(from: current, recipient: seat, seq: seq)
            try? await send(.snapshot(snapshot), to: peer)
        }
    }

    /// 重连补发：沿用当前 seq（引擎未变更）。已见过该 seq 的客机按 seq 门丢弃（快照不回退），
    /// 断线期间错过最新一帧的客机则借此补齐。
    private func resendCurrentSnapshots() async {
        guard let current = state else { return }
        for (seat, peer) in peerBySeat where seat != 0 {
            let snapshot = TableSnapshot.make(from: current, recipient: seat, seq: seq)
            try? await send(.snapshot(snapshot), to: peer)
        }
    }

    private func sendToSeat(_ seat: Int, _ payload: Payload) async {
        guard let peer = peerBySeat[seat] else { return }
        try? await send(payload, to: peer)
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
            await handleGamePayload(envelope.payload, seat: seat)
        default:
            break
        }
    }

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
        // 对局期：deviceBySeat 保留（可重连）；若断线者正是行动者，托管推进后走统一后处理
        // （扇出使 seq 前进 + 通知 UI）——重连补发按最新 seq 送出更新帧，客机 seq 门不回退。
        await publishLobby()
        if phase == .playing || phase == .finished { await afterEngineChange() }
    }

    private func bind(peer: PeerID, seat: Int) {
        seatByPeer[peer] = seat
        peerBySeat[seat] = peer
    }

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

    private func send(_ payload: Payload, to peer: PeerID) async throws {
        try await transport.send(
            try PokerWire.encode(PokerEnvelope(roomID: roomID, sender: .host, payload: payload)),
            to: peer)
    }
}
