import Foundation

/// 进程内配对传输：所有会话层测试与联调不碰真实网络。
final class LoopbackTransportHub: @unchecked Sendable {
    nonisolated(unsafe) private let lock = NSLock()
    nonisolated(unsafe) private var endpoints: [PeerID: LoopbackTransport] = [:]
    nonisolated(unsafe) private var hostID: PeerID?

    nonisolated func makeTransport(peerID: PeerID) -> LoopbackTransport {
        let transport = LoopbackTransport(peerID: peerID, hub: self)
        lock.withLock { endpoints[peerID] = transport }
        return transport
    }

    nonisolated fileprivate func host(_ peerID: PeerID) { lock.withLock { hostID = peerID } }
    nonisolated fileprivate func hostPeer() -> PeerID? { lock.withLock { hostID } }
    nonisolated fileprivate func endpoint(_ peerID: PeerID) -> LoopbackTransport? { lock.withLock { endpoints[peerID] } }
    nonisolated fileprivate func remove(_ peerID: PeerID) { lock.withLock { endpoints[peerID] = nil } }

    /// 模拟断链（锁屏/网络抖动）：两端各收 disconnected，端点保留、重拨可达。
    nonisolated func severLink(between a: PeerID, and b: PeerID) {
        let pair = lock.withLock { (endpoints[a], endpoints[b]) }
        guard let transportA = pair.0, let transportB = pair.1 else { return }
        Task { await transportA.sever(b); await transportB.sever(a) }
    }
}

actor LoopbackTransport: Transport {
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    private let peerID: PeerID
    private let hub: LoopbackTransportHub
    private var connectedPeers: Set<PeerID> = []

    fileprivate init(peerID: PeerID, hub: LoopbackTransportHub) {
        self.peerID = peerID
        self.hub = hub
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    static func makePair(first: PeerID, second: PeerID) -> (LoopbackTransport, LoopbackTransport) {
        let hub = LoopbackTransportHub()
        return (hub.makeTransport(peerID: first), hub.makeTransport(peerID: second))
    }

    func startHosting(roomID: String, port: UInt16?) async throws { hub.host(peerID) }

    func browse() async throws {
        if let host = hub.hostPeer() { continuation.yield(.discovered(host)) }
    }

    func connect(to peer: PeerID) async throws {
        guard let remote = hub.endpoint(peer) else { throw TransportError.notConnected }
        connectedPeers.insert(peer)
        await remote.accept(peerID)
        continuation.yield(.connected(peer))
    }

    func send(_ data: Data, to peer: PeerID) async throws {
        guard connectedPeers.contains(peer), let remote = hub.endpoint(peer) else {
            throw TransportError.notConnected
        }
        await remote.receive(data, from: peerID)
    }

    func disconnect() async {
        let peers = connectedPeers
        connectedPeers.removeAll()
        for peer in peers { await hub.endpoint(peer)?.drop(peerID) }
        continuation.finish()
        hub.remove(peerID)
    }

    func isConnected(to peer: PeerID) async -> Bool { connectedPeers.contains(peer) }

    private func accept(_ peer: PeerID) { connectedPeers.insert(peer); continuation.yield(.connected(peer)) }
    private func receive(_ data: Data, from peer: PeerID) { continuation.yield(.received(data, from: peer)) }
    private func drop(_ peer: PeerID) { connectedPeers.remove(peer); continuation.yield(.disconnected(peer, nil)) }

    fileprivate func sever(_ peer: PeerID) {
        guard connectedPeers.remove(peer) != nil else { return }
        continuation.yield(.disconnected(peer, nil))
    }
}

extension LoopbackTransport {
    /// 测试入口：断链注册表在 hub 手里，从传输实例转发（brief 测试要求 hostT.severLink 可同步调用）。
    nonisolated func severLink(between a: PeerID, and b: PeerID) { hub.severLink(between: a, and: b) }
}
