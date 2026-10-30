import XCTest
@testable import PokerApp

final class LoopbackTransportTests: XCTestCase {
    let host = PeerID(rawValue: "ROOM-1")
    let guest = PeerID(rawValue: "guest-a")

    func testLoopbackDeliversOrderedAsyncStreamEvents() async throws {
        let (hostT, guestT) = LoopbackTransport.makePair(first: host, second: guest)
        let log = EventLog()
        let pump = attachEvents(of: guestT, to: log)
        defer { pump.cancel() }

        try await hostT.startHosting(roomID: "ROOM-1", port: nil)
        try await guestT.connect(to: host)
        try await hostT.send(Data("first".utf8), to: guest)
        try await hostT.send(Data("second".utf8), to: guest)

        let received = try await log.waitFor { event in
            if case .received = event { return true }
            return false
        }
        guard case let .received(data, from) = received else { return XCTFail() }
        XCTAssertEqual(data, Data("first".utf8))
        XCTAssertEqual(from, host)
        let second = try await log.waitFor { event in
            if case .received = event { return true }
            return false
        }
        guard case let .received(data2, _) = second else { return XCTFail() }
        XCTAssertEqual(data2, Data("second".utf8))
    }

    func testSeverLinkNotifiesBothEndsAndAllowsReconnect() async throws {
        let (hostT, guestT) = LoopbackTransport.makePair(first: host, second: guest)
        let hostLog = EventLog(), guestLog = EventLog()
        let pumpA = attachEvents(of: hostT, to: hostLog)
        let pumpB = attachEvents(of: guestT, to: guestLog)
        defer { pumpA.cancel(); pumpB.cancel() }

        try await hostT.startHosting(roomID: "ROOM-1", port: nil)
        try await guestT.connect(to: host)
        hostT.severLink(between: host, and: guest)

        _ = try await guestLog.waitFor { if case .disconnected = $0 { return true }; return false }
        _ = try await hostLog.waitFor { if case .disconnected = $0 { return true }; return false }

        // 重拨可达：客机再次 connect，双方恢复收发
        try await guestT.connect(to: host)
        try await hostT.send(Data("again".utf8), to: guest)
        _ = try await guestLog.waitFor { event in
            if case let .received(d, _) = event { return d == Data("again".utf8) }
            return false
        }
    }

    func testSendToUnconnectedPeerThrows() async throws {
        let (hostT, guestT) = LoopbackTransport.makePair(first: host, second: guest)
        _ = guestT
        try await hostT.startHosting(roomID: "ROOM-1", port: nil)
        do {
            try await hostT.send(Data("x".utf8), to: guest)
            XCTFail("未连接应抛 notConnected")
        } catch { /* 预期 */ }
    }
}
