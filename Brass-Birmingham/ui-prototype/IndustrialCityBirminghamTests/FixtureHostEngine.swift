import Foundation
@testable import IndustrialCityBirmingham

func repairCardFixture(
    _ state: inout GameCore.GameState,
    catalog: GameCore.VerifiedGameDataCatalog
) {
    repairIndustryFixture(&state, catalog: catalog)
    var remaining = catalog.catalog.cards
        .filter { $0.playerCounts.contains(state.playerCount) }
        .flatMap { definition in
            (1...definition.count).map {
                GameCore.CardInstance(id: "\(definition.id)-\($0)", definitionID: definition.id)
            }
        }

    func canonicalize(_ cards: inout [GameCore.CardInstance]) {
        for index in cards.indices {
            if let exact = remaining.firstIndex(of: cards[index]) {
                remaining.remove(at: exact)
            } else if let sameDefinition = remaining.firstIndex(where: {
                $0.definitionID == cards[index].definitionID
            }) {
                cards[index] = remaining.remove(at: sameDefinition)
            }
        }
    }

    if state.era == .rail {
        for index in state.players.indices { state.players[index].privateBottomDiscard = nil }
    }
    let activeIndex = state.players.firstIndex { $0.id == state.activePlayerID }
    let playerIndices = activeIndex.map { active in
        [active] + state.players.indices.filter { $0 != active }
    }
        ?? Array(state.players.indices)
    for index in playerIndices {
        canonicalize(&state.players[index].hand)
        if state.era == .canal, var bottom = state.players[index].privateBottomDiscard {
            var cards = [bottom]
            canonicalize(&cards)
            bottom = cards[0]
            state.players[index].privateBottomDiscard = bottom
        }
    }
    canonicalize(&state.publicDiscard)
    state.standardDrawDeck = remaining.filter {
        $0.definitionID != "wild-location" && $0.definitionID != "wild-industry"
    }
    state.wildLocationPool = remaining.filter { $0.definitionID == "wild-location" }
    state.wildIndustryPool = remaining.filter { $0.definitionID == "wild-industry" }

    let capacity = state.era == .canal
        ? state.canalRoundCapacity
        : state.railRoundCapacity
    let expectedPlayableCount: Int
    switch state.turnPhase {
    case .active:
        let actionBudget = GameCore.TurnRules.actionsPerTurn(
            era: state.era, roundNumber: state.roundNumber
        )
        let remainingTurns = max(0, state.playerCount - state.turnsCompletedInRound - 1)
        let remainingCurrentRoundActions = remainingTurns * actionBudget
            + state.actionsRemaining
        expectedPlayableCount = max(0, remainingCurrentRoundActions)
            + max(0, capacity - state.roundNumber) * state.playerCount * 2
    case .forcedSale:
        expectedPlayableCount = max(0, capacity - state.roundNumber) * state.playerCount * 2
    case .ended:
        expectedPlayableCount = 0
    }

    if let expectedCounts = expectedCardZoneCounts(state) {
        for playerID in state.playerOrder {
            guard let playerIndex = state.players.firstIndex(where: { $0.id == playerID }),
                  let expectedHandCount = expectedCounts.hands[playerID]
            else { continue }
            if state.players[playerIndex].hand.count > expectedHandCount {
                let excess = state.players[playerIndex].hand.count - expectedHandCount
                state.standardDrawDeck.append(
                    contentsOf: state.players[playerIndex].hand.suffix(excess)
                )
                state.players[playerIndex].hand.removeLast(excess)
            } else if state.players[playerIndex].hand.count < expectedHandCount {
                let missing = expectedHandCount - state.players[playerIndex].hand.count
                let drawCount = min(missing, state.standardDrawDeck.count)
                state.players[playerIndex].hand.append(
                    contentsOf: state.standardDrawDeck.prefix(drawCount)
                )
                state.standardDrawDeck.removeFirst(drawCount)
            }
        }
        if state.standardDrawDeck.count > expectedCounts.deck {
            let excess = state.standardDrawDeck.count - expectedCounts.deck
            state.publicDiscard.append(contentsOf: state.standardDrawDeck.suffix(excess))
            state.standardDrawDeck.removeLast(excess)
        } else if state.standardDrawDeck.count < expectedCounts.deck {
            let missing = expectedCounts.deck - state.standardDrawDeck.count
            let restoreCount = min(missing, state.publicDiscard.count)
            state.standardDrawDeck.append(contentsOf: state.publicDiscard.suffix(restoreCount))
            state.publicDiscard.removeLast(restoreCount)
        }
    } else {
        let handCount = state.players.reduce(0) { $0 + $1.hand.count }
        let playableCount = handCount + state.standardDrawDeck.count
        if playableCount > expectedPlayableCount {
            let count = min(playableCount - expectedPlayableCount, state.standardDrawDeck.count)
            state.publicDiscard.append(contentsOf: state.standardDrawDeck.suffix(count))
            state.standardDrawDeck.removeLast(count)
        } else if playableCount < expectedPlayableCount {
            let count = min(expectedPlayableCount - playableCount, state.publicDiscard.count)
            state.standardDrawDeck.append(contentsOf: state.publicDiscard.suffix(count))
            state.publicDiscard.removeLast(count)
        }
    }
}

func repairIndustryFixture(
    _ state: inout GameCore.GameState,
    catalog: GameCore.VerifiedGameDataCatalog
) {
    for playerIndex in state.players.indices {
        let playerID = state.players[playerIndex].id
        let color = state.players[playerIndex].color
        let canonicalTiles = catalog.catalog.industries.flatMap { definition in
            definition.levels.flatMap { level in
                (1...level.copiesPerColor).map { copy in
                    GameCore.IndustryTile(
                        id: "\(color.rawValue)-\(definition.id)-\(level.level)-\(copy)",
                        industryDefinitionID: definition.id,
                        level: level.level
                    )
                }
            }
        }
        let canonicalByID = Dictionary(uniqueKeysWithValues: canonicalTiles.map { ($0.id, $0) })
        var usedIDs = Set<String>()

        for placementIndex in state.boardIndustryPlacements.indices
        where state.boardIndustryPlacements[placementIndex].ownerID == playerID {
            let placementTile = state.boardIndustryPlacements[placementIndex].tile
            let exactCanonical = canonicalByID[placementTile.id] == placementTile
            var selectedTile: GameCore.IndustryTile?
            if exactCanonical {
                selectedTile = placementTile
                for stackIndex in state.players[playerIndex].industryStacks.indices {
                    if let tileIndex = state.players[playerIndex].industryStacks[stackIndex].tiles
                        .firstIndex(where: { $0.id == placementTile.id }) {
                        state.players[playerIndex].industryStacks[stackIndex].tiles.remove(at: tileIndex)
                        break
                    }
                }
            } else if let stackIndex = state.players[playerIndex].industryStacks.firstIndex(where: {
                $0.industryDefinitionID == placementTile.industryDefinitionID
            }), let tileIndex = state.players[playerIndex].industryStacks[stackIndex].tiles.firstIndex(where: {
                $0.level == placementTile.level && canonicalByID[$0.id] == $0
            }) {
                selectedTile = state.players[playerIndex].industryStacks[stackIndex].tiles.remove(at: tileIndex)
            } else {
                let occupiedIDs = Set(state.players[playerIndex].industryStacks.flatMap(\.tiles).map(\.id))
                selectedTile = canonicalTiles.first {
                    $0.industryDefinitionID == placementTile.industryDefinitionID
                        && $0.level == placementTile.level
                        && usedIDs.contains($0.id) == false
                        && occupiedIDs.contains($0.id) == false
                }
            }
            if let selectedTile, usedIDs.insert(selectedTile.id).inserted {
                state.boardIndustryPlacements[placementIndex].tile = selectedTile
            }
        }

        for stackIndex in state.players[playerIndex].industryStacks.indices {
            for tileIndex in state.players[playerIndex].industryStacks[stackIndex].tiles.indices {
                let tile = state.players[playerIndex].industryStacks[stackIndex].tiles[tileIndex]
                if canonicalByID[tile.id] == tile, usedIDs.insert(tile.id).inserted {
                    continue
                }
                if let replacement = canonicalTiles.first(where: {
                    $0.industryDefinitionID == tile.industryDefinitionID
                        && $0.level == tile.level
                        && usedIDs.contains($0.id) == false
                }) {
                    state.players[playerIndex].industryStacks[stackIndex].tiles[tileIndex] = replacement
                    usedIDs.insert(replacement.id)
                }
            }
        }
    }
}

private func expectedCardZoneCounts(
    _ state: GameCore.GameState
) -> (deck: Int, hands: [GameCore.PlayerID: Int])? {
    let capacity = state.era == .canal ? state.canalRoundCapacity : state.railRoundCapacity
    guard (2...4).contains(state.playerCount),
          capacity == 12 - state.playerCount,
          (1...capacity).contains(state.roundNumber),
          state.playerOrder.count == state.playerCount,
          Set(state.playerOrder) == Set(state.players.map(\.id))
    else { return nil }
    let actionSlots = state.era == .canal
        ? state.playerCount + (capacity - 1) * state.playerCount * 2
        : capacity * state.playerCount * 2
    var deck = actionSlots - state.playerCount * 8
    guard deck >= 0 else { return nil }
    var hands = Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, 8) })

    func completeTurn(_ playerID: GameCore.PlayerID, budget: Int) -> Bool {
        guard let hand = hands[playerID], hand >= budget else { return false }
        let afterActions = hand - budget
        let refill = min(8 - afterActions, deck)
        hands[playerID] = afterActions + refill
        deck -= refill
        return true
    }
    if state.roundNumber > 1 {
        for round in 1..<state.roundNumber {
            let budget = GameCore.TurnRules.actionsPerTurn(era: state.era, roundNumber: round)
            for playerID in state.playerOrder where completeTurn(playerID, budget: budget) == false {
                return nil
            }
        }
    }
    let currentBudget = GameCore.TurnRules.actionsPerTurn(
        era: state.era, roundNumber: state.roundNumber
    )
    switch state.turnPhase {
    case .active:
        guard state.playerOrder.indices.contains(state.turnsCompletedInRound),
              (1...currentBudget).contains(state.actionsRemaining)
        else { return nil }
        for seat in 0..<state.turnsCompletedInRound
        where completeTurn(state.playerOrder[seat], budget: currentBudget) == false {
            return nil
        }
        let active = state.playerOrder[state.turnsCompletedInRound]
        let taken = currentBudget - state.actionsRemaining
        guard let activeHand = hands[active], activeHand >= taken else { return nil }
        hands[active] = activeHand - taken
    case .forcedSale, .ended:
        for playerID in state.playerOrder where completeTurn(playerID, budget: currentBudget) == false {
            return nil
        }
    }
    return (deck, hands)
}

/// Protocol-only adapter for fixtures that intentionally do not model a verified game.
/// Production HostEngine has no legacy-state or catalog-free submission path.
struct FixtureHostEngine {
    private(set) var state: GameCore.AuthoritativeGameState
    let protocolVersion: Int
    let rulesetVersion: String

    mutating func submit(_ intent: GameCore.PlayerIntent) -> GameCore.SubmissionResult {
        if let rejection = validate(intent) { return .rejected(rejection) }
        guard case .pass(let passIntent) = intent.payload,
              let playerIndex = state.players.firstIndex(where: { $0.id == intent.senderID }),
              let cardIndex = state.players[playerIndex].hand.firstIndex(of: passIntent.cardID)
        else { return .rejected(rejection(.missingDiscardCard)) }
        let previous = state.authoritativeVersion
        state.players[playerIndex].hand.remove(at: cardIndex)
        state.discardPile.append(passIntent.cardID)
        state.actionNumber += 1
        state.turn += 1
        state.authoritativeVersion = .init(rawValue: previous.rawValue + 1)
        state.activePlayerID = state.players[(playerIndex + 1) % state.players.count].id
        return .accepted(.init(
            roomID: state.roomID, actor: intent.senderID, previousVersion: previous,
            version: state.authoritativeVersion, actionNumber: state.actionNumber,
            payload: .passed(discardedCardID: passIntent.cardID)
        ))
    }

    func snapshot(for recipient: GameCore.PlayerID) throws -> GameCore.ViewSnapshot {
        guard state.players.contains(where: { $0.id == recipient }) else {
            throw GameCore.ProjectionError.unknownRecipient
        }
        let players = state.players.map {
            GameCore.VisiblePlayer(
                id: $0.id, handCount: $0.hand.count,
                hand: $0.id == recipient ? $0.hand : nil
            )
        }
        return .init(
            roomID: state.roomID, recipient: recipient, players: players,
            activePlayerID: state.activePlayerID, turn: state.turn,
            actionNumber: state.actionNumber,
            authoritativeVersion: state.authoritativeVersion,
            discardPile: state.discardPile,
            checksum: try GameCore.snapshotChecksum(
                roomID: state.roomID, recipient: recipient, players: players,
                activePlayerID: state.activePlayerID, turn: state.turn,
                actionNumber: state.actionNumber,
                authoritativeVersion: state.authoritativeVersion,
                discardPile: state.discardPile
            )
        )
    }

    func clientEvent(
        _ event: GameCore.AuthoritativeGameEvent,
        for recipient: GameCore.PlayerID
    ) throws -> GameCore.ClientEvent {
        .init(event: event, snapshot: try snapshot(for: recipient))
    }

    private func validate(_ intent: GameCore.PlayerIntent) -> GameCore.RejectedIntent? {
        guard intent.roomID == state.roomID else { return rejection(.wrongRoom) }
        guard intent.protocolVersion == protocolVersion else { return rejection(.protocolVersionMismatch) }
        guard intent.rulesetVersion == rulesetVersion else { return rejection(.rulesetVersionMismatch) }
        guard intent.baseVersion == state.authoritativeVersion else { return rejection(.staleAuthoritativeVersion) }
        guard let player = state.players.first(where: { $0.id == intent.senderID }) else {
            return rejection(.unknownSender)
        }
        guard player.reconnectToken == intent.reconnectToken else { return rejection(.invalidReconnectToken) }
        guard intent.senderID == state.activePlayerID else { return rejection(.notActivePlayer) }
        guard case .pass(let passIntent) = intent.payload,
              player.hand.contains(passIntent.cardID)
        else { return rejection(.missingDiscardCard) }
        return nil
    }

    private func rejection(_ reason: GameCore.RejectedIntent.ReasonCode) -> GameCore.RejectedIntent {
        .init(reasonCode: reason, recoverySuggestion: "Refresh the fixture state and retry.")
    }
}
