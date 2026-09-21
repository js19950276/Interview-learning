import Foundation

extension GameCore {
    nonisolated struct PassIntent: Codable, Equatable, Sendable { var cardID: String }
    nonisolated struct LoanIntent: Codable, Equatable, Sendable { var cardID: String }
    nonisolated struct ScoutIntent: Codable, Equatable, Sendable { var cardIDs: [String] }

    nonisolated struct ValidatedPassTarget: Equatable, Sendable {
        let actorID: PlayerID
        let intent: PassIntent
        let card: CardInstance

        fileprivate init(actorID: PlayerID, intent: PassIntent, card: CardInstance) {
            self.actorID = actorID
            self.intent = intent
            self.card = card
        }
    }

    nonisolated struct ValidatedLoanTarget: Equatable, Sendable {
        let actorID: PlayerID
        let intent: LoanIntent
        let card: CardInstance
        let incomePosition: Int

        fileprivate init(actorID: PlayerID, intent: LoanIntent, card: CardInstance, incomePosition: Int) {
            self.actorID = actorID
            self.intent = intent
            self.card = card
            self.incomePosition = incomePosition
        }
    }

    nonisolated struct ValidatedScoutTarget: Equatable, Sendable {
        let actorID: PlayerID
        let intent: ScoutIntent
        let cards: [CardInstance]
        let wildLocationCard: CardInstance?
        let wildIndustryCard: CardInstance?

        fileprivate init(
            actorID: PlayerID, intent: ScoutIntent, cards: [CardInstance],
            wildLocationCard: CardInstance?, wildIndustryCard: CardInstance?
        ) {
            self.actorID = actorID
            self.intent = intent
            self.cards = cards
            self.wildLocationCard = wildLocationCard
            self.wildIndustryCard = wildIndustryCard
        }
    }

    nonisolated struct ValidatedEraConfirmation: Equatable, Sendable {
        let actorID: PlayerID
    }

    nonisolated enum SimpleActionRuleError: String, Codable, Equatable, Error, Sendable {
        case notActivePlayer, missingCard, invalidState, incomeFloor, invalidScoutCards
        case duplicateScoutCard, nonStandardCard, wildHeld, wildPoolEmpty
    }

    nonisolated enum SimpleActionRules {
        static func validatePass(
            _ intent: PassIntent,
            actorID: PlayerID,
            state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> ValidatedPassTarget {
            guard GameStateAuthorityValidator.isValid(state, catalog: verifiedCatalog) else {
                throw SimpleActionRuleError.invalidState
            }
            guard state.activePlayerID == actorID,
                  let player = state.players.first(where: { $0.id == actorID })
            else { throw SimpleActionRuleError.notActivePlayer }
            guard let card = player.hand.first(where: { $0.id == intent.cardID })
            else { throw SimpleActionRuleError.missingCard }
            return ValidatedPassTarget(actorID: actorID, intent: intent, card: card)
        }

        /// 时代结算确认:处于结算暂停阶段、玩家尚未确认过即可确认。
        static func validateEraConfirmation(
            actorID: PlayerID,
            state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> ValidatedEraConfirmation {
            guard GameStateAuthorityValidator.isValid(state, catalog: verifiedCatalog) else {
                throw SimpleActionRuleError.invalidState
            }
            guard state.players.contains(where: { $0.id == actorID }) else {
                throw SimpleActionRuleError.notActivePlayer
            }
            guard case .eraIntermission(let intermission) = state.turnPhase,
                  intermission.confirmedPlayerIDs.contains(actorID) == false
            else { throw SimpleActionRuleError.invalidState }
            return ValidatedEraConfirmation(actorID: actorID)
        }

        static func validateLoan(
            _ intent: LoanIntent,
            actorID: PlayerID,
            state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> ValidatedLoanTarget {
            guard state.activePlayerID == actorID,
                  let player = state.players.first(where: { $0.id == actorID })
            else { throw SimpleActionRuleError.notActivePlayer }
            guard let card = player.hand.first(where: { $0.id == intent.cardID })
            else { throw SimpleActionRuleError.missingCard }
            let entries = verifiedCatalog.catalog.incomeTrack.entries
            guard let currentIncome = entries.first(where: { $0.position == player.incomePosition })?.income else {
                throw SimpleActionRuleError.incomeFloor
            }
            let (targetIncome, overflow) = currentIncome.subtractingReportingOverflow(3)
            guard !overflow else {
                throw GameRulesEngine.GameRulesInternalError.arithmeticOverflow
            }
            guard targetIncome >= -10,
                  let targetPosition = entries.filter({ $0.income == targetIncome }).map(\.position).max()
            else { throw SimpleActionRuleError.incomeFloor }
            return ValidatedLoanTarget(
                actorID: actorID, intent: intent, card: card, incomePosition: targetPosition
            )
        }

        static func validateScout(
            _ intent: ScoutIntent,
            actorID: PlayerID,
            state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> ValidatedScoutTarget {
            guard state.activePlayerID == actorID,
                  let player = state.players.first(where: { $0.id == actorID })
            else { throw SimpleActionRuleError.notActivePlayer }
            let definitions = Dictionary(uniqueKeysWithValues: verifiedCatalog.catalog.cards.map { ($0.id, $0) })
            let heldKinds = player.hand.compactMap { definitions[$0.definitionID]?.kind }
            guard heldKinds.contains(.wildLocation) == false, heldKinds.contains(.wildIndustry) == false
            else { throw SimpleActionRuleError.wildHeld }
            guard intent.cardIDs.count == 3 else { throw SimpleActionRuleError.invalidScoutCards }
            guard Set(intent.cardIDs).count == 3 else { throw SimpleActionRuleError.duplicateScoutCard }
            let cards = intent.cardIDs.compactMap { id in player.hand.first(where: { $0.id == id }) }
            guard cards.count == 3 else { throw SimpleActionRuleError.missingCard }
            guard cards.allSatisfy({
                guard let kind = definitions[$0.definitionID]?.kind else { return false }
                return kind == .location || kind == .industry
            }) else { throw SimpleActionRuleError.nonStandardCard }
            // 万能堆空时侦察仍可执行,只是拿不到对应堆的牌(官方规则)。
            return ValidatedScoutTarget(
                actorID: actorID, intent: intent, cards: cards,
                wildLocationCard: state.wildLocationPool.last,
                wildIndustryCard: state.wildIndustryPool.last
            )
        }
    }
}
