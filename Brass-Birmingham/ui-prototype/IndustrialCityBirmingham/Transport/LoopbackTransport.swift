import Foundation

final class LoopbackTransportHub: @unchecked Sendable {
    nonisolated(unsafe) private let lock = NSLock()
    nonisolated(unsafe) private var endpoints: [GameCore.PlayerID: LoopbackTransport] = [:]
    nonisolated(unsafe) private var hostID: GameCore.PlayerID?

    nonisolated func makeTransport(peerID: GameCore.PlayerID) -> LoopbackTransport {
        let transport = LoopbackTransport(peerID: peerID, hub: self)
        lock.withLock { endpoints[peerID] = transport }
        return transport
    }

    nonisolated fileprivate func host(_ peerID: GameCore.PlayerID) { lock.withLock { hostID = peerID } }
    nonisolated fileprivate func hostPeer() -> GameCore.PlayerID? { lock.withLock { hostID } }
    nonisolated fileprivate func endpoint(_ peerID: GameCore.PlayerID) -> LoopbackTransport? { lock.withLock { endpoints[peerID] } }
    nonisolated fileprivate func remove(_ peerID: GameCore.PlayerID) { lock.withLock { endpoints[peerID] = nil } }
}

actor LoopbackTransport: Transport {
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    private let peerID: GameCore.PlayerID
    private let hub: LoopbackTransportHub
    private var connectedPeers: Set<GameCore.PlayerID> = []

    fileprivate init(peerID: GameCore.PlayerID, hub: LoopbackTransportHub) {
        self.peerID = peerID
        self.hub = hub
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    static func makePair(first: GameCore.PlayerID, second: GameCore.PlayerID) -> (LoopbackTransport, LoopbackTransport) {
        let hub = LoopbackTransportHub()
        return (hub.makeTransport(peerID: first), hub.makeTransport(peerID: second))
    }

    func startHosting(roomID: GameCore.RoomID, port: UInt16?) async throws { hub.host(peerID) }
    func browse() async throws {
        if let host = hub.hostPeer() { continuation.yield(.discovered(host)) }
    }

    func connect(to peer: GameCore.PlayerID) async throws {
        guard let remote = hub.endpoint(peer) else { throw TransportError.notConnected }
        connectedPeers.insert(peer)
        await remote.accept(peerID)
        continuation.yield(.connected(peer))
    }

    func send(_ data: Data, to peer: GameCore.PlayerID) async throws {
        guard connectedPeers.contains(peer), let remote = hub.endpoint(peer) else { throw TransportError.notConnected }
        await remote.receive(data, from: peerID)
    }

    func disconnect() async {
        let peers = connectedPeers
        connectedPeers.removeAll()
        for peer in peers { await hub.endpoint(peer)?.drop(peerID) }
        continuation.finish()
        hub.remove(peerID)
    }

    private func accept(_ peer: GameCore.PlayerID) { connectedPeers.insert(peer); continuation.yield(.connected(peer)) }
    private func receive(_ data: Data, from peer: GameCore.PlayerID) { continuation.yield(.received(data, from: peer)) }
    private func drop(_ peer: GameCore.PlayerID) { connectedPeers.remove(peer); continuation.yield(.disconnected(peer, nil)) }
}
