import Foundation

@testable import IndustrialCityBirmingham

/// 脚本化对局驱动支持:回合结束需确认后,驱动循环在"待确认"阶段
/// 替当前行动玩家补一发 confirmTurnEnd,保持原有推进节奏。
enum TurnEndDriving {
    /// 若引擎处于待确认阶段,替当前行动玩家提交确认;返回是否已提交。
    @discardableResult
    static func confirmIfAwaiting(
        _ engine: inout GameCore.HostEngine,
        roomID: GameCore.RoomID,
        tokens: [GameCore.PlayerID: GameCore.ReconnectToken],
        catalog: GameCore.VerifiedGameDataCatalog
    ) -> Bool {
        guard case .awaitingTurnEndConfirmation = engine.gameState.turnPhase,
              let actor = engine.gameState.activePlayerID
        else { return false }
        let current = engine.gameState
        let result = engine.submit(
            .init(
                protocolVersion: 2, rulesetVersion: current.rulesetVersion,
                roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
                baseVersion: current.authoritativeVersion, payload: .confirmTurnEnd
            ),
            catalog: catalog
        )
        guard case .accepted = result else {
            return false
        }
        return true
    }
}
