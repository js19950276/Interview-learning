import XCTest
import PokerEngine
@testable import PokerApp

/// 大厅阶段：建房/加入分配座位/ready/满员拒绝/版本拒绝/改名广播。
/// 「裸客机」直接用 LoopbackTransport + sendEnvelope 模拟（GuestSession 在 Task 9 才有）。
final class HostSessionLobbyTests: XCTestCase {
    let hostPeer = PeerID(rawValue: "ROOM-X")
    var hub: LoopbackTransportHub!
    var hostTransport: LoopbackTransport!
    var guestTransport: LoopbackTransport!
    var guestLog: EventLog!
    var pump: Task<Void, Never>!

    override func setUp() async throws {
        hub = LoopbackTransportHub()
        hostTransport = hub.makeTransport(peerID: hostPeer)
        guestTransport = hub.makeTransport(peerID: PeerID(rawValue: "guest-raw"))
        guestLog = EventLog()
    }

    override func tearDown() async throws {
        pump?.cancel()
        await hostSessionForTeardown?.disconnect()
    }

    private var hostSessionForTeardown: HostSession?

    private func makeHost() -> HostSession {
        let config = HostConfiguration(
            roomName: "周五牌局", hostName: "老王",
            tableConfig: GameConfig(playerCount: 2, startingStack: 2000, format: .cash(sb: 10, bb: 20)))
        let session = HostSession(configuration: config, transport: hostTransport)
        hostSessionForTeardown = session
        return session
    }

    /// 从客机传输事件流取下一条房主发来的信封。host→guest 方向的消息只出现在客机侧；
    /// 且 AsyncStream 单消费者——HostSession 消费 hostTransport 的流，测试泵只能挂 guestTransport。
    private func nextEnvelope(timeout: TimeInterval = 3) async throws -> (PokerEnvelope, PeerID) {
        while true {
            let event = try await guestLog.waitFor(timeout: timeout) { if case .received = $0 { return true }; return false }
            guard case let .received(data, from) = event,
                  let envelope = try? PokerWire.decode(data) else { continue }
            return (envelope, from)
        }
    }

    func testStartHostingPublishesLobbyWithHostSeat() async throws {
        let host = makeHost()
        let updates = host.updates
        try await host.startHosting()
        var received: LobbyState?
        for await update in updates {
            if case let .lobby(lobby) = update { received = lobby; break }
        }
        XCTAssertEqual(received?.players.map(\.seat), [0])
        XCTAssertEqual(received?.players[0].isHost, true)
        XCTAssertEqual(received?.roomName, "周五牌局")
        let phase = await host.currentPhase()
        XCTAssertEqual(phase, .lobby)
        let roomID = await host.roomIDValue()
        XCTAssertTrue(roomID.hasPrefix("ROOM-"), "中文房间名清洗后兜底为 ROOM + 随机后缀，实际: \(roomID)")
    }

    func testJoinAssignsSeatsInOrderAndBroadcastsLobby() async throws {
        let host = makeHost()
        try await host.startHosting()
        pump = attachEvents(of: guestTransport, to: guestLog)
        try await guestTransport.connect(to: hostPeer)
        try await sendEnvelope(.hello(deviceID: "device-A", name: "阿明"), roomID: await host.roomIDValue(),
                               sender: .guest, from: guestTransport, to: hostPeer)
        let (welcome, _) = try await nextEnvelope()
        guard case let .welcome(seat, lobby) = welcome.payload else { return XCTFail("应回 welcome") }
        XCTAssertEqual(seat, 1)
        XCTAssertEqual(lobby.players.map(\.seat), [0, 1])
        XCTAssertEqual(lobby.players[1].name, "阿明")
        // 随后广播 lobby 给在座客机
        let (broadcast, _) = try await nextEnvelope()
        guard case .lobby = broadcast.payload else { return XCTFail("应广播 lobby") }
    }

    func testReadyFlowUpdatesLobby() async throws {
        let host = makeHost()
        try await host.startHosting()
        pump = attachEvents(of: guestTransport, to: guestLog)
        try await guestTransport.connect(to: hostPeer)
        try await sendEnvelope(.hello(deviceID: "device-A", name: "阿明"), roomID: await host.roomIDValue(),
                               sender: .guest, from: guestTransport, to: hostPeer)
        _ = try await nextEnvelope()   // welcome
        _ = try await nextEnvelope()   // lobby 广播
        try await sendEnvelope(.ready(true), roomID: await host.roomIDValue(), sender: .seat(1),
                               from: guestTransport, to: hostPeer)
        let (lobby, _) = try await nextEnvelope()
        guard case let .lobby(state) = lobby.payload else { return XCTFail() }
        XCTAssertEqual(state.players[1].ready, true)
        XCTAssertFalse(state.players[0].ready, "房主尚未 ready")
    }

    func testVersionMismatchRejected() async throws {
        let host = makeHost()
        try await host.startHosting()
        pump = attachEvents(of: guestTransport, to: guestLog)
        try await guestTransport.connect(to: hostPeer)
        let bad = PokerEnvelope(protocolVersion: PokerProtocolVersion.current + 1,
                                roomID: await host.roomIDValue(), sender: .guest,
                                payload: .hello(deviceID: "device-B", name: "旧版"))
        try await guestTransport.send(try PokerWire.encode(bad), to: hostPeer)
        let (rejection, _) = try await nextEnvelope()
        XCTAssertEqual(rejection.payload, .rejection(.versionMismatch))
    }

    func testLobbyPhaseDisconnectFreesSeat() async throws {
        let host = makeHost()
        try await host.startHosting()
        pump = attachEvents(of: guestTransport, to: guestLog)
        try await guestTransport.connect(to: hostPeer)
        try await sendEnvelope(.hello(deviceID: "device-A", name: "阿明"), roomID: await host.roomIDValue(),
                               sender: .guest, from: guestTransport, to: hostPeer)
        _ = try await nextEnvelope()   // welcome
        _ = try await nextEnvelope()   // lobby 广播
        hub.severLink(between: hostPeer, and: PeerID(rawValue: "guest-raw"))
        // 断链后客机传输已不可达，名册广播只达在座者——改为从房主侧观测名册变化
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await host.currentLobby()?.players.map(\.seat) == [0] {
                let boundPeer = await host.peerIDValue(seat: 1)
                XCTAssertNil(boundPeer, "座位 1 的对端绑定已解除")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let lobby = await host.currentLobby()
        XCTFail("大厅期断线即移出名册，实际名册座位: \(lobby.map { $0.players.map(\.seat) } ?? [])")
    }
}
