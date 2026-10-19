import Foundation

extension GameCore {
    /// 模拟专用"瘦提交":复刻 HostEngine 的 validate→resolve 分发,
    /// 跳过身份校验、GameStateAuthorityValidator 与投影构建。
    /// 规则解析逻辑与宿主路径逐行同源,状态推进必须等价(对拍测试锁定)。
    nonisolated enum SimulationRunner {
        enum SimulationError: Error, Equatable, Sendable {
            case unsupportedRetracement
        }

        static func apply(
            _ payload: PlayerIntent.Payload,
            actorID: PlayerID,
            roomID: RoomID,
            to state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws {
            switch payload {
            case .pass(let intent):
                let target = try SimpleActionRules.validatePass(
                    intent, actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameRulesEngine.resolvePass(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .build(let intent):
                let target = try BuildRules.validate(
                    intent, actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameRulesEngine.resolveBuild(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .network(let intent):
                let target = try NetworkRules.validate(
                    intent, actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameRulesEngine.resolveNetwork(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .develop(let intent):
                let target = try DevelopRules.validate(
                    intent, actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameCore.GameRulesEngine.resolveDevelop(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .sell(let intent):
                let target = try SellRules.validate(
                    intent, actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameCore.GameRulesEngine.resolveSell(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .loan(let intent):
                let target = try SimpleActionRules.validateLoan(
                    intent, actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameCore.GameRulesEngine.resolveLoan(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .scout(let intent):
                let target = try SimpleActionRules.validateScout(
                    intent, actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameCore.GameRulesEngine.resolveScout(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .forcedSale(let intent):
                _ = try GameCore.GameRulesEngine.resolveForcedSale(
                    intent, actorID: actorID, roomID: roomID, state: &state, catalog: catalog
                )
            case .confirmEraIntermission:
                let target = try SimpleActionRules.validateEraConfirmation(
                    actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameCore.GameRulesEngine.resolveEraConfirmation(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .confirmTurnEnd:
                let target = try SimpleActionRules.validateTurnEndConfirmation(
                    actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameCore.GameRulesEngine.resolveTurnEndConfirmation(
                    actorID: target.actorID, roomID: roomID, state: &state, catalog: catalog
                )
            case .retractTurnActions:
                throw SimulationError.unsupportedRetracement
            }
        }
    }
}
