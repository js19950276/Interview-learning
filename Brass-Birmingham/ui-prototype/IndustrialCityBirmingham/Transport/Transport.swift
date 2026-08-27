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
}
