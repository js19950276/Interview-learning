import CryptoKit
import Foundation

extension GameCore {
    nonisolated enum ActionKind: String, Codable, CaseIterable, Equatable, Sendable {
        case build, network, develop, sell, loan, scout, pass, forcedSale
    }

    nonisolated struct ConfirmationDelta: Codable, Equatable, Sendable {
        var cashDelta: Int
        var incomeDelta: Int
        var victoryPointDelta: Int
        var resourceEffects: [ResourceEffect] = []
    }

    nonisolated struct ActionOption: Codable, Equatable, Sendable {
        var id: String
        var action: ActionKind
        var cardIDs: [String]
        var targetIDs: [String]
        var payload: PlayerIntent.Payload
        var confirmation: ConfirmationDelta
    }

    nonisolated enum LegalChoiceValue: Codable, Equatable, Sendable {
        case industryTile(id: String)
        case buildTarget(locationID: String, slotIndex: Int)
        case route(id: String)
        case industryPlacement(id: String)
        case merchant(id: String)
        case card(id: String)
        case resourceSource(ResourceSource)
        case networkLinkCount(Int)
        case developTileCount(Int)
        case sellDisposition(continueSelling: Bool)
    }

    nonisolated struct LegalChoice: Codable, Equatable, Sendable {
        var id: String
        var label: String
        var value: LegalChoiceValue
    }

    nonisolated struct LegalActionDraft: Codable, Equatable, Sendable {
        var action: ActionKind
        var cardID: String?
        var selections: [LegalChoiceValue]

        func canonicalDigest() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(self)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    nonisolated struct LegalActionQuery: Codable, Equatable, Sendable {
        var requestID: String
        var baseVersion: AuthoritativeVersion
        var draft: LegalActionDraft
    }

    nonisolated struct LegalActionResponse: Codable, Equatable, Sendable {
        var requestID: String
        var baseVersion: AuthoritativeVersion
        var draftDigest: String = ""
        var nextChoices: [LegalChoice]
        var confirmation: ConfirmationDelta?
        var completePayload: PlayerIntent.Payload?
        var error: LegalActionQueryError? = nil
    }

    nonisolated struct MatchPlayerProjection: Codable, Equatable, Sendable {
        var id: PlayerID
        var color: PlayerColor
        var handCount: Int
        var cash: Int
        var incomePosition: Int
        var victoryPoints: Int
        var spent: Int
        var linksRemaining: Int
        var industryStacks: [IndustryStack]?
    }

    nonisolated struct MatchProjection: Codable, Equatable, Sendable {
        var era: Era
        var roundNumber: Int
        var deckCount: Int
        var actionsRemaining: Int
        var players: [MatchPlayerProjection]
        var boardIndustryPlacements: [BoardIndustryPlacement]
        var placedLinks: [PlacedLink]
        var coalMarket: ResourceMarket
        var ironMarket: ResourceMarket
        var publicSupply: PublicSupply
        var merchants: [MerchantPlacement]
        var forcedSaleDebtorID: PlayerID?
        var publicChecksum: String
        var ownHand: [CardInstance]
        var availableActions: [ActionKind]
        var availableActionsByCardID: [String: [ActionKind]]?
        var trivialOptions: [ActionOption]

        static func make(
            state: GameState,
            recipient: PlayerID,
            actionOptions: [ActionOption]
        ) throws -> MatchProjection {
            var projection = MatchProjection(
                era: state.era,
                roundNumber: state.roundNumber,
                deckCount: state.standardDrawDeck.count,
                actionsRemaining: state.actionsRemaining,
                players: state.players.map { player in
                    MatchPlayerProjection(
                        id: player.id,
                        color: player.color,
                        handCount: player.hand.count,
                        cash: player.cash,
                        incomePosition: player.incomePosition,
                        victoryPoints: player.victoryPoints,
                        spent: player.spent,
                        linksRemaining: player.linksRemaining,
                        industryStacks: player.id == recipient ? player.industryStacks : nil
                    )
                },
                boardIndustryPlacements: state.boardIndustryPlacements,
                placedLinks: state.placedLinks,
                coalMarket: state.coalMarket,
                ironMarket: state.ironMarket,
                publicSupply: state.publicSupply,
                merchants: state.merchants,
                forcedSaleDebtorID: {
                    if case .forcedSale(let pending) = state.turnPhase { return pending.playerID }
                    return nil
                }(),
                publicChecksum: "",
                ownHand: state.players.first(where: { $0.id == recipient })?.hand ?? [],
                availableActions: Array(Set(actionOptions.map(\.action))).sorted { $0.rawValue < $1.rawValue },
                availableActionsByCardID: Dictionary(
                    uniqueKeysWithValues: (state.players.first(where: { $0.id == recipient })?.hand ?? [])
                        .map { ($0.id, []) }
                ),
                trivialOptions: actionOptions
            )
            projection.publicChecksum = try projection.computePublicChecksum()
            return projection
        }

        func canonicalBytes() throws -> Data {
            try JSONEncoder.canonical.encode(self)
        }

        private func computePublicChecksum() throws -> String {
            struct PublicMaterial: Encodable {
                var era: Era
                var roundNumber: Int
                var deckCount: Int
                var actionsRemaining: Int
                var players: [MatchPlayerProjection]
                var boardIndustryPlacements: [BoardIndustryPlacement]
                var placedLinks: [PlacedLink]
                var coalMarket: ResourceMarket
                var ironMarket: ResourceMarket
                var publicSupply: PublicSupply
                var merchants: [MerchantPlacement]
                var forcedSaleDebtorID: PlayerID?
            }
            let material = PublicMaterial(
                era: era, roundNumber: roundNumber, deckCount: deckCount,
                actionsRemaining: actionsRemaining,
                players: players.map {
                    var visible = $0
                    visible.industryStacks = nil
                    return visible
                },
                boardIndustryPlacements: boardIndustryPlacements, placedLinks: placedLinks,
                coalMarket: coalMarket, ironMarket: ironMarket,
                publicSupply: publicSupply, merchants: merchants,
                forcedSaleDebtorID: forcedSaleDebtorID
            )
            return try CanonicalChecksum.sha256(material)
        }

        func isRecipientSafe(recipient: PlayerID, visibleHand: [String]) -> Bool {
            let ids = players.map(\.id)
            guard Set(ids).count == ids.count,
                  publicChecksum == (try? computePublicChecksum()),
                  players.contains(where: { $0.id == recipient && $0.industryStacks != nil }),
                  players.allSatisfy({ $0.id == recipient || $0.industryStacks == nil }),
                  ownHand.map(\.id) == visibleHand,
                  let availableActionsByCardID,
                  Set(availableActionsByCardID.keys) == Set(visibleHand),
                  availableActionsByCardID.values.allSatisfy({ actions in
                      Set(actions).count == actions.count && !actions.contains(.forcedSale)
                  }),
                  Set(availableActions) == Set(availableActionsByCardID.values.flatMap { $0 })
            else { return false }
            let handIDs = Set(visibleHand)
            return trivialOptions.allSatisfy { option in
                Set(option.cardIDs).isSubset(of: handIDs)
                    && (option.action == .pass || option.action == .loan)
            }
        }
    }
}
