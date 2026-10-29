import Foundation

/// 传输层对端标识。客机侧 = 房间（Bonjour 实例名）；房主侧 = 每条已接受连接的临时 UUID。
struct PeerID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

enum TransportEvent: Equatable, Sendable {
    case discovered(PeerID)
    case connected(PeerID)
    case received(Data, from: PeerID)
    case disconnected(PeerID, TransportError?)
}

enum TransportError: String, Codable, Error, Sendable {
    case zeroLengthFrame
    case frameTooLarge
    case decoderShutDown
    case notConnected
    case invalidPort
    case connectionFailed
}

protocol Transport: Sendable {
    var events: AsyncStream<TransportEvent> { get async }
    func startHosting(roomID: String, port: UInt16?) async throws
    func browse() async throws
    func connect(to peer: PeerID) async throws
    func send(_ data: Data, to peer: PeerID) async throws
    func disconnect() async
    /// 指定对端连接当前是否就绪；供前台自愈探测「静默断链」。
    func isConnected(to peer: PeerID) async -> Bool
    /// 进程挂起/恢复后的传输层自愈；房主侧确保监听器仍可被发现。
    func reviveHostingIfNeeded() async
}

extension Transport {
    func isConnected(to peer: PeerID) async -> Bool { true }
    func reviveHostingIfNeeded() async {}
}
