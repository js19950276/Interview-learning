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
