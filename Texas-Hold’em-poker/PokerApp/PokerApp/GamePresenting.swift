import Foundation
import PokerEngine

/// 对局界面的统一驱动面：单机(GameViewModel)/房主(HostGameViewModel)/客机(GuestGameViewModel)。
@MainActor
protocol GamePresenting: ObservableObject {
    var surface: (any TableSurface)? { get }
    var humanLegal: LegalActions? { get }
    var lastResult: HandResult? { get }
    var isHandOver: Bool { get }
    var isSessionOver: Bool { get }
    func act(_ action: PlayerAction) async
    func nextHand() async
    func driveBots() async
}

extension GamePresenting {
    /// 联机无机器人；单机 VM 自带实现。
    func driveBots() async {}
}
