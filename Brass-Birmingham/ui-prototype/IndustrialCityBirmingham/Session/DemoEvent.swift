#if DEBUG
nonisolated struct DemoIntent: Equatable, Sendable {
    let action: GameAction
    let selectedCardID: String
    let targetIDs: [String]
}

nonisolated struct DemoEvent: Equatable, Sendable {
    let version: Int
    let title: String
    let effects: [DemoEffect]
}

nonisolated enum DemoEffect: Equatable, Sendable {
    case moveResource(kind: IndustryKind, from: String, to: String)
    case marketChanged(coal: MarketSummary, iron: MarketSummary)
    case industryFlipped(String)
    case incomeChanged(from: Int, to: Int)
    case actionAdvanced(from: Int, to: Int)
}

nonisolated struct RejectedIntent: Error, Equatable, Sendable {
    let reason: String
    let recoverySuggestion: String
}

nonisolated struct TechnicalSubmissionFailure: Equatable, Sendable {
    let diagnostic: String
    let retrySuggestion: String
}

nonisolated enum DemoSubmissionOutcome: Equatable, Sendable {
    case accepted(DemoEvent)
    case rejected(RejectedIntent)
    case technicalFailure(TechnicalSubmissionFailure)
}

nonisolated struct DemoSubmissionSnapshot: Equatable, Sendable {
    let generation: Int
    let intent: DemoIntent
    let actionNumber: Int
}

nonisolated struct DemoSubmissionGate: Equatable, Sendable {
    private var generation = 0
    private var activeGeneration: Int?

    var isSubmitting: Bool {
        activeGeneration != nil
    }

    mutating func begin(intent: DemoIntent, actionNumber: Int) -> DemoSubmissionSnapshot {
        generation += 1
        activeGeneration = generation
        return DemoSubmissionSnapshot(
            generation: generation,
            intent: intent,
            actionNumber: actionNumber
        )
    }

    mutating func invalidate() {
        generation += 1
        activeGeneration = nil
    }

    func shouldApply(
        snapshot: DemoSubmissionSnapshot,
        currentIntent: DemoIntent?,
        currentActionNumber: Int,
        eventVersion: Int?
    ) -> Bool {
        guard activeGeneration == snapshot.generation,
              currentIntent == snapshot.intent,
              currentActionNumber == snapshot.actionNumber else { return false }
        return eventVersion == nil || eventVersion == snapshot.actionNumber + 1
    }

    mutating func finish(snapshot: DemoSubmissionSnapshot) -> Bool {
        guard activeGeneration == snapshot.generation else { return false }
        activeGeneration = nil
        return true
    }
}

nonisolated enum DemoEventFixture {
    static func event(
        for intent: DemoIntent,
        state: DemoMatchState,
        fixture: ActionFixture = .standard
    ) throws -> DemoEvent {
        try validate(intent: intent, state: state, fixture: fixture)
        let nextActionNumber = state.actionNumber + 1

        switch intent.action {
        case .build:
            let target = intent.targetIDs[0]
            let coal = consuming(state.coalMarket, quantity: 1)
            return DemoEvent(
                version: nextActionNumber,
                title: "建造行动已接受",
                effects: [
                    .moveResource(kind: .coal, from: "coal-market", to: target),
                    .marketChanged(coal: coal, iron: state.ironMarket),
                    .industryFlipped("industry-coal"),
                    .incomeChanged(from: state.income, to: state.income + 1),
                    .actionAdvanced(from: state.actionNumber, to: nextActionNumber)
                ]
            )
        case .network:
            let target = intent.targetIDs[0]
            let coal = consuming(state.coalMarket, quantity: 1)
            return DemoEvent(
                version: nextActionNumber,
                title: "网络行动已接受",
                effects: [
                    .moveResource(kind: .coal, from: "coal-market", to: target),
                    .marketChanged(coal: coal, iron: state.ironMarket),
                    .actionAdvanced(from: state.actionNumber, to: nextActionNumber)
                ]
            )
        case .develop:
            let iron = consuming(state.ironMarket, quantity: intent.targetIDs.count)
            return DemoEvent(
                version: nextActionNumber,
                title: "发展行动已接受",
                effects: intent.targetIDs.flatMap { industryID in
                    [
                        .moveResource(kind: .iron, from: "iron-market", to: industryID),
                        .industryFlipped(industryID)
                    ]
                } + [
                    .marketChanged(coal: state.coalMarket, iron: iron),
                    .actionAdvanced(from: state.actionNumber, to: nextActionNumber)
                ]
            )
        case .sell:
            let optionID = intent.targetIDs[0]
            guard let industryID = fixture.sellOptions.first(where: { $0.id == optionID })?.industryID else {
                throw rejection("出售选项 \(optionID) 不在当前演示行动中。")
            }
            return DemoEvent(
                version: nextActionNumber,
                title: "出售行动已接受",
                effects: [
                    .industryFlipped(industryID),
                    .incomeChanged(from: state.income, to: state.income + 1),
                    .actionAdvanced(from: state.actionNumber, to: nextActionNumber)
                ]
            )
        case .loan:
            return DemoEvent(
                version: nextActionNumber,
                title: "贷款行动已接受",
                effects: [
                    .incomeChanged(from: state.income, to: state.income - 3),
                    .actionAdvanced(from: state.actionNumber, to: nextActionNumber)
                ]
            )
        case .scout:
            return DemoEvent(
                version: nextActionNumber,
                title: "侦察行动已接受",
                effects: [.actionAdvanced(from: state.actionNumber, to: nextActionNumber)]
            )
        case .pass:
            return DemoEvent(
                version: nextActionNumber,
                title: "跳过行动已接受",
                effects: [.actionAdvanced(from: state.actionNumber, to: nextActionNumber)]
            )
        }
    }

    private static func validate(
        intent: DemoIntent,
        state: DemoMatchState,
        fixture: ActionFixture
    ) throws {
        guard fixture.availableActions.contains(intent.action) else {
            throw rejection("行动 \(intent.action.rawValue) 不在当前演示行动中。")
        }
        guard let selectedCard = state.hand.first(where: { $0.id == intent.selectedCardID }) else {
            throw rejection("手牌 \(intent.selectedCardID) 不在当前手牌中。")
        }
        guard selectedCard.allowedActions.contains(intent.action) else {
            throw rejection("手牌 \(intent.selectedCardID) 不允许执行 \(intent.action.rawValue)。")
        }
        guard validTargetCount(for: intent.action).contains(intent.targetIDs.count) else {
            throw rejection("行动 \(intent.action.rawValue) 的目标数量无效。")
        }
        guard Set(intent.targetIDs).count == intent.targetIDs.count else {
            throw rejection("行动目标不可重复。")
        }
        guard intent.action != .scout || intent.targetIDs.contains(intent.selectedCardID) == false else {
            throw rejection("侦察额外手牌不能包含行动牌。")
        }

        let allowedTargetIDs = targetIDs(for: intent.action, fixture: fixture)
        if let invalidTarget = intent.targetIDs.first(where: { allowedTargetIDs.contains($0) == false }) {
            throw rejection("目标 \(invalidTarget) 不在当前演示行动中。")
        }
    }

    private static func validTargetCount(for action: GameAction) -> ClosedRange<Int> {
        switch action {
        case .build, .sell:
            1...1
        case .network, .develop:
            1...2
        case .scout:
            2...2
        case .loan, .pass:
            0...0
        }
    }

    private static func targetIDs(for action: GameAction, fixture: ActionFixture) -> Set<String> {
        switch action {
        case .build:
            Set(fixture.buildLocationIDs)
        case .network:
            Set(fixture.networkRouteIDs)
        case .develop:
            Set(fixture.developIndustryIDs)
        case .sell:
            Set(fixture.sellOptions.map(\.id))
        case .scout:
            Set(fixture.scoutCardIDs)
        case .loan, .pass:
            []
        }
    }

    private static func consuming(_ market: MarketSummary, quantity: Int) -> MarketSummary {
        guard quantity > 0 else { return market }
        var updated = market
        updated.remaining = max(0, market.remaining - quantity)
        updated.cheapestPrice = market.cheapestPrice + 1
        return updated
    }

    private static func rejection(_ reason: String) -> RejectedIntent {
        RejectedIntent(
            reason: reason,
            recoverySuggestion: "请保留当前草稿，并从高亮的可用目标中重新选择。"
        )
    }
}

nonisolated enum DemoEventReducer {
    static func applying(_ event: DemoEvent, to state: DemoMatchState) -> DemoMatchState {
        var nextState = state
        for effect in event.effects {
            switch effect {
            case .moveResource:
                break
            case .marketChanged(let coal, let iron):
                nextState.coalMarket = coal
                nextState.ironMarket = iron
            case .industryFlipped(let industryID):
                guard let index = nextState.industries.firstIndex(where: { $0.id == industryID }) else {
                    continue
                }
                nextState.industries[index].isAvailable.toggle()
            case .incomeChanged(_, let newIncome):
                nextState.income = newIncome
            case .actionAdvanced(_, let newActionNumber):
                nextState.actionNumber = newActionNumber
            }
        }
        return nextState
    }
}

nonisolated struct DemoNormalizedPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

nonisolated struct DemoResourceMotion: Equatable, Sendable {
    let kind: IndustryKind
    let sourceID: String
    let destinationID: String
    let source: DemoNormalizedPoint
    let destination: DemoNormalizedPoint
    let startsAtDestination: Bool

    var id: String {
        "\(kind.rawValue):\(sourceID):\(destinationID)"
    }
}

nonisolated enum DemoHaptic: Equatable, Sendable {
    case light
    case medium
    case success
}

nonisolated struct DemoFeedbackPlan: Equatable, Sendable {
    let usesMarketNumericTransition: Bool
    let resourceMotions: [DemoResourceMotion]
    let flippedIndustryIDs: Set<String>
    let haptics: [DemoHaptic]
    let announcementTitle: String

    var initialDestinationMotionIDs: Set<String> {
        Set(resourceMotions.filter(\.startsAtDestination).map(\.id))
    }

    var finalDestinationMotionIDs: Set<String> {
        Set(resourceMotions.map(\.id))
    }

    static func make(
        event: DemoEvent,
        state: DemoMatchState,
        reduceMotion: Bool,
        hapticsEnabled: Bool
    ) -> DemoFeedbackPlan {
        let resourceMotions = event.effects.compactMap { effect -> DemoResourceMotion? in
            guard case .moveResource(let kind, let sourceID, let destinationID) = effect,
                  let source = anchor(for: sourceID, state: state),
                  let destination = anchor(for: destinationID, state: state) else { return nil }
            return DemoResourceMotion(
                kind: kind,
                sourceID: sourceID,
                destinationID: destinationID,
                source: source,
                destination: destination,
                startsAtDestination: reduceMotion
            )
        }
        let flippedIndustryIDs = Set(event.effects.compactMap { effect -> String? in
            guard case .industryFlipped(let id) = effect else { return nil }
            return id
        })
        let changesMarket = event.effects.contains { effect in
            if case .marketChanged = effect { true } else { false }
        }

        return DemoFeedbackPlan(
            usesMarketNumericTransition: changesMarket && reduceMotion == false,
            resourceMotions: resourceMotions,
            flippedIndustryIDs: flippedIndustryIDs,
            haptics: hapticsEnabled ? [.light, .medium, .success] : [],
            announcementTitle: event.title
        )
    }

    private static func anchor(for id: String, state: DemoMatchState) -> DemoNormalizedPoint? {
        switch id {
        case "coal-market":
            return DemoNormalizedPoint(x: 0.12, y: 0.78)
        case "iron-market":
            return DemoNormalizedPoint(x: 0.20, y: 0.78)
        default:
            if let location = state.locations.first(where: { $0.id == id }) {
                return DemoNormalizedPoint(x: location.x, y: location.y)
            }
            if let route = state.routes.first(where: { $0.id == id }),
               let start = state.locations.first(where: { $0.id == route.fromLocationID }),
               let end = state.locations.first(where: { $0.id == route.toLocationID }) {
                return DemoNormalizedPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            }
            if let industryIndex = state.industries.firstIndex(where: { $0.id == id }) {
                return DemoNormalizedPoint(x: 0.92, y: 0.18 + Double(industryIndex) * 0.12)
            }
            return nil
        }
    }
}

nonisolated struct DemoRejectionFeedbackPlan: Equatable, Sendable {
    let accessibilityLabel: String
    let shouldFocus: Bool
    let preservesDraft: Bool

    static func make(rejection: RejectedIntent) -> DemoRejectionFeedbackPlan {
        DemoRejectionFeedbackPlan(
            accessibilityLabel: "行动未接受，\(rejection.reason)，\(rejection.recoverySuggestion)",
            shouldFocus: true,
            preservesDraft: true
        )
    }
}

nonisolated struct DemoTechnicalFailureFeedbackPlan: Equatable, Sendable {
    let accessibilityLabel: String
    let shouldFocus: Bool
    let preservesDraft: Bool

    static func make(failure: TechnicalSubmissionFailure) -> DemoTechnicalFailureFeedbackPlan {
        DemoTechnicalFailureFeedbackPlan(
            accessibilityLabel: "提交遇到技术问题，\(failure.diagnostic)，\(failure.retrySuggestion)",
            shouldFocus: true,
            preservesDraft: true
        )
    }
}
#endif
