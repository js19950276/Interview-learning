import XCTest
import Network
@testable import PokerApp

final class NearbyTransportTests: XCTestCase {
    func testParametersIncludePeerToPeerAndBypassProxies() {
        let parameters = NearbyTransport.makeParameters()
        XCTAssertTrue(parameters.includePeerToPeer, "无路由器的点对点 Wi-Fi 也要能连（spec §5）")
        XCTAssertTrue(parameters.preferNoProxies)
    }

    func testServiceTypeIsPokerLan() {
        XCTAssertEqual(NearbyTransport.serviceType, "_poker-lan._tcp")
    }

    /// 监听器冒烟：模拟器内可无 launch switch 起监听（移植 Brass 同名用例）。
    func testTransportCanHostAnAdvertisedRoom() async throws {
        let transport = NearbyTransport()
        do {
            try await transport.startHosting(roomID: "POKER-UNIT-HOST", port: nil)
            await transport.disconnect()
        } catch {
            await transport.disconnect()
            throw error
        }
    }

    func testTerminationRegistryIgnoresStaleAndDuplicateTermination() {
        let peer = PeerID(rawValue: "peer")
        let first = NSObject(); let replacement = NSObject()
        var registry = ConnectionTerminationRegistry()
        registry.register(first, for: peer)
        registry.register(replacement, for: peer)
        XCTAssertFalse(registry.terminate(first, for: peer), "被替换的旧连接不得触发终止")
        XCTAssertTrue(registry.contains(replacement, for: peer))
        XCTAssertTrue(registry.terminate(replacement, for: peer))
        XCTAssertFalse(registry.terminate(replacement, for: peer), "重复终止只算一次")
    }

    func testRoomNameSanitizeStripsToAsciiAndCaps() {
        XCTAssertEqual(RoomName.sanitize("房主的 德州桌!"), "ROOM", "非 ASCII 全部折叠为分隔符后为空名，兜底 ROOM")
        XCTAssertEqual(RoomName.sanitize("My Room 7"), "MY-ROOM-7")
        XCTAssertEqual(RoomName.sanitize("!!!"), "ROOM", "空名兜底")
    }

    func testBrowserDedupesAndRemovesRoomListings() async throws {
        let driver = FakeRoomBrowserDriver()
        let browser = BonjourRoomBrowser(driver: driver)
        let states = browser.states
        await browser.start()
        driver.emit(.ready)
        driver.emit(.added(RoomListing(id: "a", serviceName: "ROOM-A")))
        driver.emit(.added(RoomListing(id: "a", serviceName: "ROOM-A")))   // 同 id 重复：忽略
        driver.emit(.added(RoomListing(id: "b", serviceName: "ROOM-B")))
        driver.emit(.removed("a"))
        driver.emit(.removed("a"))                                          // 重复移除：忽略
        var collected: [RoomBrowseState] = []
        for await state in states {
            collected.append(state)
            if case .found(let rooms) = state, rooms.map(\.serviceName) == ["ROOM-B"] { break }
        }
        await browser.cancel()
        guard case .found(let finalRooms) = collected.last else { return XCTFail("应停留在 found") }
        XCTAssertEqual(finalRooms.map(\.serviceName), ["ROOM-B"])
    }
}

/// 可手动注入更新的假驱动（浏览去重逻辑测试用）。
final class FakeRoomBrowserDriver: RoomBrowsing, @unchecked Sendable {
    let updates: AsyncStream<RoomBrowserUpdate>
    private let continuation: AsyncStream<RoomBrowserUpdate>.Continuation

    init() {
        (updates, continuation) = AsyncStream.makeStream(of: RoomBrowserUpdate.self)
    }

    func emit(_ update: RoomBrowserUpdate) { continuation.yield(update) }
    func start() {}
    func cancel() { continuation.finish() }
}
