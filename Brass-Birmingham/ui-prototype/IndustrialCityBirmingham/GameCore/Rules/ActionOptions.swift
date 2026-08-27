import Foundation

extension GameCore {
    nonisolated enum ExactCompletionSearch {
        enum Step<Node> { case complete, branches([Node]), deadEnd }

        static func containsCompletion<Node>(
            root: Node,
            key: (Node) throws -> String,
            expand: (Node) throws -> Step<Node>,
            isDeadEndError: (any Error) -> Bool = { _ in false }
        ) throws -> Bool {
            var memo: [String: Bool] = [:]
            var visiting: Set<String> = []
            func visit(_ node: Node) throws -> Bool {
                let nodeKey = try key(node)
                if let cached = memo[nodeKey] { return cached }
                guard visiting.insert(nodeKey).inserted else { return false }
                defer { visiting.remove(nodeKey) }
                let result: Bool
                switch try expand(node) {
                case .complete:
                    result = true
                case .deadEnd:
                    result = false
                case .branches(let children):
                    result = try children.contains { child in
                        do { return try visit(child) }
                        catch where isDeadEndError(error) { return false }
                    }
                }
                memo[nodeKey] = result
                return result
            }
            do { return try visit(root) }
            catch where isDeadEndError(error) { return false }
        }
    }

    nonisolated enum SnapshotActionAvailability {
        static func make(
            state: GameState,
            recipient: PlayerID,
            catalog: VerifiedGameDataCatalog
        ) throws -> (kinds: [ActionKind], byCardID: [String: [ActionKind]], trivialOptions: [ActionOption]) {
            guard let player = state.players.first(where: { $0.id == recipient }) else {
                return ([], [:], [])
            }
            guard state.activePlayerID == recipient, state.turnPhase == .active else {
                return ([], Dictionary(uniqueKeysWithValues: player.hand.map { ($0.id, []) }), [])
            }

            var kinds: Set<ActionKind> = []
            var byCardID: [String: [ActionKind]] = [:]
            var trivial: [ActionOption] = []
            for card in player.hand {
                var cardKinds: [ActionKind] = []
                for action in ActionKind.allCases where action != .forcedSale {
                    let draft = LegalActionDraft(action: action, cardID: card.id, selections: [])
                    if try hasCompletablePath(
                        draft: draft, actorID: recipient, state: state, catalog: catalog
                    ) {
                        cardKinds.append(action)
                        kinds.insert(action)
                    }
                }
                cardKinds.sort { $0.rawValue < $1.rawValue }
                byCardID[card.id] = cardKinds
                if cardKinds.contains(.pass) {
                    trivial.append(option(.pass(.init(cardID: card.id)), action: .pass, cardID: card.id))
                }
                if cardKinds.contains(.loan) {
                    trivial.append(option(.loan(.init(cardID: card.id)), action: .loan, cardID: card.id))
                }
            }
            return (
                kinds.sorted { $0.rawValue < $1.rawValue }, byCardID,
                trivial.sorted { $0.id < $1.id }
            )
        }

        private static func hasCompletablePath(
            draft: LegalActionDraft,
            actorID: PlayerID,
            state: GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> Bool {
            try ExactCompletionSearch.containsCompletion(
                root: draft,
                key: { try $0.canonicalDigest() },
                expand: { current in
                    let query = LegalActionQuery(
                        requestID: "availability", baseVersion: state.authoritativeVersion,
                        draft: current
                    )
                    let response = try LegalActionQueryEngine.respond(
                        to: query, actorID: actorID, state: state, catalog: catalog
                    )
                    if response.completePayload != nil { return .complete }
                    guard !response.nextChoices.isEmpty else { return .deadEnd }
                    return .branches(response.nextChoices.map { choice in
                        var next = current
                        next.selections.append(choice.value)
                        return next
                    })
                },
                isDeadEndError: { $0 is LegalActionQueryError }
            )
        }

        private static func option(
            _ payload: PlayerIntent.Payload,
            action: ActionKind,
            cardID: String
        ) -> ActionOption {
            let delta = action == .loan
                ? ConfirmationDelta(cashDelta: 30, incomeDelta: -3, victoryPointDelta: 0)
                : ConfirmationDelta(cashDelta: 0, incomeDelta: 0, victoryPointDelta: 0)
            return .init(
                id: "\(action.rawValue):\(cardID)", action: action,
                cardIDs: [cardID], targetIDs: [], payload: payload, confirmation: delta
            )
        }
    }
}
