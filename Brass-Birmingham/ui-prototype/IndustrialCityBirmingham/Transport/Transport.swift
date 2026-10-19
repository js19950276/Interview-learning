import Foundation

nonisolated enum TransportEvent: Equatable, Sendable {
    case discovered(GameCore.PlayerID)
    case connected(GameCore.PlayerID)
    case received(Data, from: GameCore.PlayerID)
    case disconnected(GameCore.PlayerID, TransportError?)
}
nonisolated enum TransportError: String, Codable, Equatable, Error, Sendable {
    case zeroLengthFrame
    case frameTooLarge
    case decoderShutDown
    case notConnected
    case invalidPort
    case connectionFailed
}

nonisolated protocol Transport: Sendable {
    var events: AsyncStream<TransportEvent> { get async }
    func startHosting(roomID: GameCore.RoomID, port: UInt16?) async throws
    func browse() async throws
    func connect(to peer: GameCore.PlayerID) async throws
    func send(_ data: Data, to peer: GameCore.PlayerID) async throws
    func disconnect() async
    /// 指定对端的连接当前是否就绪;供前台自愈探测"静默断链"。
    func isConnected(to peer: GameCore.PlayerID) async -> Bool
    /// 进程挂起/恢复后的传输层自愈;房主侧确保监听器仍可被发现。
    func reviveHostingIfNeeded() async
}

extension Transport {
    func isConnected(to peer: GameCore.PlayerID) async -> Bool { true }
    func reviveHostingIfNeeded() async {}
}
