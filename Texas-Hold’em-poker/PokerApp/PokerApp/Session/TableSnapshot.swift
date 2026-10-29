import Foundation
import PokerEngine

// MARK: - wire 快照值类型

struct SnapshotPlayer: Codable, Equatable, Sendable {
    var seat: Int
    var name: String
    var stack: Int
    var streetContribution: Int
    var status: PlayerStatus
    /// 有牌但对接收者不可见（UI 画牌背）。
    var holdsCards: Bool
    /// 仅接收者本人（或摊牌亮出）的牌，其余恒为空数组。
    var holeCards: [Card]
}

struct TableSnapshot: Codable, Equatable, Sendable {
    /// 主机单调递增；客机丢弃 seq <= 已见最大值的快照。
    var seq: Int
    var config: GameConfig
    var handNumber: Int
    var buttonSeat: Int
    var street: Street
    var board: [Card]
    /// 下标即 seat。
    var players: [SnapshotPlayer]
    var potTotal: Int
    var currentBet: Int
    var actorSeat: Int?
    var handResult: HandResult?
    var tournamentOver: Bool
    var tournamentPayouts: [TournamentPayout]
    var yourSeat: Int
    /// 轮到接收者时由主机用引擎 legalActions() 算好附上（规则唯一真源在引擎）。
    var yourLegal: LegalActions?
}

extension TableSnapshot {
    /// 由权威引擎状态生成 recipient 专属脱敏快照（spec §7 三条规则）。
    static func make(from state: GameState, recipient seat: Int, seq: Int) -> TableSnapshot {
        // 摊牌局（handResult 含非空 ranks）才亮牌；全员弃牌收池的 ranks 为空 → 不亮
        let showdownReached = state.street == .handOver
            && !(state.handResult?.awards.first?.ranks.isEmpty ?? true)
        let players = state.players.map { p -> SnapshotPlayer in
            let visible = p.seat == seat || (showdownReached && p.status != .folded)
            return SnapshotPlayer(
                seat: p.seat, name: p.name, stack: p.stack,
                streetContribution: p.streetContribution, status: p.status,
                holdsCards: !p.holeCards.isEmpty,
                holeCards: visible ? p.holeCards : [])
        }
        let yourLegal: LegalActions?
        if state.actorSeat == seat, [.preflop, .flop, .turn, .river].contains(state.street) {
            yourLegal = legalActions(state)
        } else {
            yourLegal = nil
        }
        return TableSnapshot(
            seq: seq, config: state.config, handNumber: state.handNumber,
            buttonSeat: state.buttonSeat, street: state.street, board: state.board,
            players: players, potTotal: state.potTotal, currentBet: state.currentBet,
            actorSeat: state.actorSeat, handResult: state.handResult,
            tournamentOver: state.tournamentOver,
            tournamentPayouts: state.tournamentPayouts,
            yourSeat: seat, yourLegal: yourLegal)
    }
}

// MARK: - UI 渲染投影协议（spec §10.1）

protocol SeatSurface: Sendable {
    var seat: Int { get }
    var name: String { get }
    var stack: Int { get }
    var streetContribution: Int { get }
    var status: PlayerStatus { get }
    var holeCards: [Card] { get }
    var holdsCards: Bool { get }
}

protocol TableSurface: Sendable {
    var seats: [any SeatSurface] { get }
    var board: [Card] { get }
    var street: Street { get }
    var actorSeat: Int? { get }
    var buttonSeat: Int { get }
    var handNumber: Int { get }
    var potTotal: Int { get }
    var currentBet: Int { get }
    var format: GameFormat { get }
    var yourSeat: Int { get }
    var handResult: HandResult? { get }
    var tournamentOver: Bool { get }
    var tournamentPayouts: [TournamentPayout] { get }
}

extension TableSurface {
    func seatPlayer(_ seat: Int) -> (any SeatSurface)? {
        seats.first { $0.seat == seat }
    }
}

// MARK: - 两个渲染路径的各自实现

// 客机路径：快照即投影。
extension SnapshotPlayer: SeatSurface {}
extension TableSnapshot: TableSurface {
    var seats: [any SeatSurface] { players }
    var format: GameFormat { config.format }
}

// 单机/房主路径：引擎类型直接满足投影（本机行为零变化）。
extension PlayerState: SeatSurface {
    var holdsCards: Bool { !holeCards.isEmpty }
}
extension GameState: TableSurface {
    var seats: [any SeatSurface] { players }
    var format: GameFormat { config.format }
    var yourSeat: Int { config.humanSeat }
}
