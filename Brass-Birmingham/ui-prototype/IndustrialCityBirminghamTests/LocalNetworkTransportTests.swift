import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct LocalNetworkTransportTests {
    @Test func frameUsesFourByteBigEndianLengthPrefix() throws {
        let framed = try LengthPrefixedFrameCodec.frame(Data([0xAA, 0xBB, 0xCC]))
        #expect(Array(framed) == [0, 0, 0, 3, 0xAA, 0xBB, 0xCC])
    }

    @Test func decoderHandlesSplitAndCoalescedReadsInOrder() throws {
        var decoder = LengthPrefixedFrameCodec.Decoder()
        let first = try LengthPrefixedFrameCodec.frame(Data("one".utf8))
        let second = try LengthPrefixedFrameCodec.frame(Data("two".utf8))
        #expect(try decoder.append(first.prefix(2)) == [])
        #expect(try decoder.append(first.dropFirst(2) + second) == [Data("one".utf8), Data("two".utf8)])
    }

    @Test(arguments: [0, LengthPrefixedFrameCodec.maximumFrameSize + 1])
    func malformedLengthPermanentlyShutsDecoder(length: Int) throws {
        var decoder = LengthPrefixedFrameCodec.Decoder()
        let prefix = Data([
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ])
        let expected: TransportError = length == 0 ? .zeroLengthFrame : .frameTooLarge
        #expect(throws: expected) { try decoder.append(prefix) }
        #expect(throws: TransportError.decoderShutDown) { try decoder.append(Data([0, 0, 0, 1, 7])) }
    }

    @Test func loopbackDeliversOrderedAsyncStreamEvents() async throws {
        let (host, guest) = LoopbackTransport.makePair(
            first: .init(rawValue: "host"), second: .init(rawValue: "guest")
        )
        let events = await guest.events
        try await host.startHosting(roomID: .init(rawValue: "ROOM"), port: nil)
        try await guest.connect(to: .init(rawValue: "host"))
        try await host.send(Data("first".utf8), to: .init(rawValue: "guest"))
        try await host.send(Data("second".utf8), to: .init(rawValue: "guest"))

        let received = try await firstThreeEvents(from: events)
        #expect(received == [
            .connected(.init(rawValue: "host")),
            .received(Data("first".utf8), from: .init(rawValue: "host")),
            .received(Data("second".utf8), from: .init(rawValue: "host")),
        ])
    }

    @Test func terminationRegistryIgnoresStaleAndDuplicateTermination() {
        let peer = GameCore.PlayerID(rawValue: "peer")
        let first = NSObject(); let replacement = NSObject()
        var registry = ConnectionTerminationRegistry()
        registry.register(first, for: peer)
        registry.register(replacement, for: peer)
        let staleTerminated = registry.terminate(first, for: peer)
        #expect(!staleTerminated)
        #expect(registry.contains(replacement, for: peer))
        let replacementTerminated = registry.terminate(replacement, for: peer)
        #expect(replacementTerminated)
        let duplicateTerminated = registry.terminate(replacement, for: peer)
        #expect(!duplicateTerminated)
    }

    @Test func callbackGateRejectsStaleReadyAndBytesAfterReplacementRegistration() {
        let peer = GameCore.PlayerID(rawValue: "peer")
        let stale = NSObject(); let current = NSObject()
        var registry = ConnectionTerminationRegistry()
        registry.register(stale, for: peer)
        registry.register(current, for: peer)
        #expect(!registry.contains(stale, for: peer))
        #expect(registry.contains(current, for: peer))
    }

    private func firstThreeEvents(from events: AsyncStream<TransportEvent>) async throws -> [TransportEvent] {
        try await withThrowingTaskGroup(of: [TransportEvent].self) { group in
            group.addTask {
                var values: [TransportEvent] = []
                for await event in events {
                    values.append(event)
                    if values.count == 3 { return values }
                }
                throw TestTimeout()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(1))
                throw TestTimeout()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private struct TestTimeout: Error {}
