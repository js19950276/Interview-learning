import Foundation
@testable import IndustrialCityBirmingham

func repairCardFixture(
    _ state: inout GameCore.GameState,
    catalog: GameCore.VerifiedGameDataCatalog
) {
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
