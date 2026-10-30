import Foundation
import PokerEngine

enum PokerProtocolVersion {
    /// wire 结构不兼容变更时 +1；不匹配的双方互相拒绝并提示升级。
    static let current = 1
}

/// 消息发送方身份。hello 尚未分配座位时用 .guest；入座后一切消息用 .seat(n)。
enum Sender: Codable, Equatable, Hashable, Sendable {
    case host
    case guest
    case seat(Int)
}

enum RejectionReason: String, Codable, Equatable, Sendable {
    case roomFull        // 大厅满员（9 座）
    case gameStarted     // 对局已开始，拒绝新面孔
    case versionMismatch // 协议版本不一致
    case illegalAction   // 引擎判定非法的动作
    case notYourTurn     // 不是该座位的行动轮
}

struct LobbyPlayer: Codable, Equatable, Sendable {
    var seat: Int
    var name: String
    var isHost: Bool
    var ready: Bool
    var connected: Bool
}

enum LobbyPhase: String, Codable, Equatable, Sendable {
    case lobby
    case playing
}

struct LobbyState: Codable, Equatable, Sendable {
    var phase: LobbyPhase
    var roomName: String
    var players: [LobbyPlayer]
    /// 房主定下的桌子配置（开局前广播给客机展示）。
    var config: GameConfig?
}

enum Payload: Codable, Equatable, Sendable {
    case hello(deviceID: String, name: String)
    case welcome(seat: Int, lobby: LobbyState)
    case rejection(RejectionReason)
    case lobby(LobbyState)
    case ready(Bool)
    case action(PlayerAction)
    case nextHand
    case snapshot(TableSnapshot)
    case bye
}

struct PokerEnvelope: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var roomID: String
    /// 接收端去重（重连补发可能与在途重叠）。
    var messageID: String
    var sender: Sender
    var payload: Payload

    init(protocolVersion: Int = PokerProtocolVersion.current,
         roomID: String, messageID: String = UUID().uuidString,
         sender: Sender, payload: Payload) {
        self.protocolVersion = protocolVersion
        self.roomID = roomID
        self.messageID = messageID
        self.sender = sender
        self.payload = payload
    }
}

enum PokerWire {
    static func encode(_ envelope: PokerEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    static func decode(_ data: Data) throws -> PokerEnvelope {
        try JSONDecoder().decode(PokerEnvelope.self, from: data)
    }
}
