import Foundation
@testable import PokerApp

struct TestTimeout: Error {}

/// 轮询式事件收集器：测试断言传输事件流内容用。
actor EventLog {
    private var buffered: [TransportEvent] = []

    func record(_ event: TransportEvent) { buffered.append(event) }

    func all() -> [TransportEvent] { buffered }

    /// 等待第一条满足条件的事件（取出并移除）；超时抛 TestTimeout。
    func waitFor(timeout: TimeInterval = 3, _ predicate: @Sendable @escaping (TransportEvent) -> Bool) async throws -> TransportEvent {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let index = buffered.firstIndex(where: predicate) { return buffered.remove(at: index) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestTimeout()
    }
}

/// 把传输事件流泵入 EventLog。
func attachEvents(of transport: any Transport, to log: EventLog) -> Task<Void, Never> {
    Task {
        let events = await transport.events
        for await event in events {
            await log.record(event)
        }
    }
}

/// 以「裸客机」身份向房主发送一条信封（会话级测试用，不经过 GuestSession）。
func sendEnvelope(_ payload: Payload, roomID: String, sender: Sender,
                  from transport: any Transport, to host: PeerID) async throws {
    try await transport.send(try PokerWire.encode(
        PokerEnvelope(roomID: roomID, sender: sender, payload: payload)
    ), to: host)
}
