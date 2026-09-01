import CryptoKit
import Foundation

extension GameCore {
    /// The release currently implements only the official standard game.
    /// Unknown encoded values must fail decoding instead of silently running
    /// under a different ruleset.
    nonisolated enum GameVariant: String, Codable, Equatable, Sendable {
        case standard
    }

    nonisolated enum Era: String, Codable, Equatable, Sendable {
        case canal
        case rail
    }

    nonisolated enum PlayerColor: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
        case red
        case yellow
        case blue
        case purple
    }

    nonisolated enum ResourceKind: String, Codable, Equatable, Hashable, Sendable {
        case beer
        case coal
        case iron
    }

    nonisolated enum AuthorityCompleteness: String, Codable, Equatable, Sendable {
        case complete
    }

    nonisolated struct CardInstance: Codable, Equatable, Hashable, Sendable {
        var id: String
        var definitionID: String
    }

    nonisolated struct IndustryTile: Codable, Equatable, Hashable, Sendable {
        var id: String
        var industryDefinitionID: String
        var level: Int
    }

    nonisolated struct IndustryStack: Codable, Equatable, Sendable {
        var industryDefinitionID: String
        var tiles: [IndustryTile]
    }

    nonisolated struct SetupPlayer: Codable, Equatable, Sendable {
        var id: PlayerID
        var color: PlayerColor
        var hand: [CardInstance]
        var privateBottomDiscard: CardInstance?
        var industryStacks: [IndustryStack]
        var cash: Int
        var incomePosition: Int
        var victoryPoints: Int
        var victoryPointDebt: Int
        var spent: Int
        var linksRemaining: Int

        init(
            id: PlayerID,
            color: PlayerColor,
            hand: [CardInstance],
            privateBottomDiscard: CardInstance?,
            industryStacks: [IndustryStack],
            cash: Int,
            incomePosition: Int,
            victoryPoints: Int,
            victoryPointDebt: Int = 0,
            spent: Int,
            linksRemaining: Int = 14
        ) {
            self.id = id
            self.color = color
            self.hand = hand
            self.privateBottomDiscard = privateBottomDiscard
            self.industryStacks = industryStacks
            self.cash = cash
            self.incomePosition = incomePosition
            self.victoryPoints = victoryPoints
            self.victoryPointDebt = victoryPointDebt
            self.spent = spent
            self.linksRemaining = linksRemaining
        }

        private enum CodingKeys: String, CodingKey {
            case id, color, hand, privateBottomDiscard, industryStacks, cash, incomePosition
            case victoryPoints, victoryPointDebt, spent, linksRemaining
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(PlayerID.self, forKey: .id)
            color = try values.decode(PlayerColor.self, forKey: .color)
            hand = try values.decode([CardInstance].self, forKey: .hand)
            privateBottomDiscard = try values.decodeIfPresent(CardInstance.self, forKey: .privateBottomDiscard)
            industryStacks = try values.decode([IndustryStack].self, forKey: .industryStacks)
            cash = try values.decode(Int.self, forKey: .cash)
            incomePosition = try values.decode(Int.self, forKey: .incomePosition)
            victoryPoints = try values.decode(Int.self, forKey: .victoryPoints)
            victoryPointDebt = try values.decodeIfPresent(Int.self, forKey: .victoryPointDebt) ?? 0
            spent = try values.decode(Int.self, forKey: .spent)
            linksRemaining = try values.decodeIfPresent(Int.self, forKey: .linksRemaining) ?? 14
        }
    }

    nonisolated struct MarketSlot: Codable, Equatable, Sendable {
        var price: Int
        var hasCube: Bool
    }

    nonisolated struct ResourceMarket: Codable, Equatable, Sendable {
        static let officialIronPrices = [1, 1, 2, 2, 3, 3, 4, 4, 5, 5]

        var resource: ResourceKind
        var slots: [MarketSlot]
    }

    nonisolated struct PublicSupply: Codable, Equatable, Sendable {
        var coal: Int
        var iron: Int
        var beer: Int
        var mayUseSubstitutes: Bool
    }

    nonisolated struct MerchantPlacement: Codable, Equatable, Sendable {
        var slotID: String
        var merchantDefinitionID: String
        var hasBeer: Bool
    }

    nonisolated struct BoardIndustryPlacement: Codable, Equatable, Sendable {
        var placementID: String
        var locationID: String
        var slotIndex: Int
        var ownerID: PlayerID
        var tile: IndustryTile
        var resourceCount: Int
        var isFlipped: Bool
        var marketDeliveryResolved: Bool

        init(
            placementID: String? = nil,
            locationID: String,
            slotIndex: Int,
            ownerID: PlayerID,
            tile: IndustryTile,
            resourceCount: Int = 0,
            isFlipped: Bool = false,
            marketDeliveryResolved: Bool = false
        ) {
            self.placementID = placementID ?? "\(locationID)#\(slotIndex)"
            self.locationID = locationID
            self.slotIndex = slotIndex
            self.ownerID = ownerID
            self.tile = tile
            self.resourceCount = resourceCount
            self.isFlipped = isFlipped
            self.marketDeliveryResolved = marketDeliveryResolved
        }

        private enum CodingKeys: String, CodingKey {
            case placementID, locationID, slotIndex, ownerID, tile, resourceCount, isFlipped
            case marketDeliveryResolved
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            locationID = try values.decode(String.self, forKey: .locationID)
            slotIndex = try values.decode(Int.self, forKey: .slotIndex)
            placementID = try values.decodeIfPresent(String.self, forKey: .placementID)
                ?? "\(locationID)#\(slotIndex)"
            ownerID = try values.decode(PlayerID.self, forKey: .ownerID)
            tile = try values.decode(IndustryTile.self, forKey: .tile)
            resourceCount = try values.decodeIfPresent(Int.self, forKey: .resourceCount) ?? 0
            isFlipped = try values.decodeIfPresent(Bool.self, forKey: .isFlipped) ?? false
            marketDeliveryResolved = try values.decodeIfPresent(
                Bool.self,
                forKey: .marketDeliveryResolved
            ) ?? false
        }
    }

    nonisolated struct PlacedLink: Codable, Equatable, Sendable {
        var routeID: String
        var ownerID: PlayerID
        var era: Era
    }

    nonisolated struct PendingForcedSale: Codable, Equatable, Sendable {
        var playerID: PlayerID
        var shortfall: Int
        var eligiblePlacementIDs: [String]
    }

    nonisolated enum TurnPhase: Codable, Equatable, Sendable {
        case active
        case forcedSale(PendingForcedSale)
        case ended
    }

    nonisolated struct GameState: Codable, Equatable, Sendable {
        var rulesetVersion: String
        /// `nil` is accepted only for backward-compatible decoding of archives
        /// written before the variant discriminator existed.
        var gameVariant: GameVariant? = .standard
        var seed: UInt64
        var playerCount: Int
        var era: Era
        var roundNumber: Int
        var actionsRemaining: Int
        var turnsCompletedInRound: Int
        var actionNumber: Int
        var canalRoundCapacity: Int
        var railRoundCapacity: Int
        var players: [SetupPlayer]
        var playerOrder: [PlayerID]
        var activePlayerID: PlayerID?
        var standardDrawDeck: [CardInstance]
        var wildLocationPool: [CardInstance]
        var wildIndustryPool: [CardInstance]
        var publicDiscard: [CardInstance]
        var boardIndustryPlacements: [BoardIndustryPlacement]
        var placedLinks: [PlacedLink]
        var coalMarket: ResourceMarket
        var ironMarket: ResourceMarket
        var publicSupply: PublicSupply
        var merchants: [MerchantPlacement]
        var authoritativeVersion: AuthoritativeVersion
        var turnPhase: TurnPhase = .active
        /// Index of the next player whose income must be resolved after a forced sale.
        var roundIncomeCursor: Int? = nil
        var authorityCompleteness: AuthorityCompleteness? = nil
        /// Bounded authoritative replay protection. `nil` denotes a legacy/incomplete state.
        var appliedResourceActionIDs: [String]? = nil
        /// Public, durable final ranking. Each inner array is a tied rank group.
        var finalStandings: [[PlayerID]]? = nil

        var resolvedGameVariant: GameVariant { gameVariant ?? .standard }

        func canonicalBytes() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self)
        }

        func canonicalHash() throws -> String {
            SHA256.hash(data: try canonicalBytes())
                .map { String(format: "%02x", $0) }
                .joined()
        }

        func makeHostEngine(
            roomID: RoomID,
            reconnectTokens: [PlayerID: ReconnectToken],
            protocolVersion: Int
        ) throws -> HostEngine {
            guard let activePlayerID else {
                throw HostEngineBridgeError.missingActivePlayer
            }
            for player in players {
                guard let reconnectToken = reconnectTokens[player.id] else {
                    throw HostEngineBridgeError.missingReconnectToken(player.id)
                }
                _ = reconnectToken
            }
            return HostEngine(
                gameState: self,
                roomID: roomID,
                reconnectTokens: reconnectTokens,
                protocolVersion: protocolVersion,
                activePlayerID: activePlayerID
            )
        }

        static func legacyCompatible(
            _ state: AuthoritativeGameState,
            rulesetVersion: String
        ) -> GameState {
            let playerCount = state.players.count
            return GameState(
                rulesetVersion: rulesetVersion,
                seed: 0,
                playerCount: playerCount,
                era: .canal,
                roundNumber: state.turn,
                actionsRemaining: 1,
                turnsCompletedInRound: max(0, playerCount - 1),
                actionNumber: state.actionNumber,
                canalRoundCapacity: max(0, 12 - playerCount),
                railRoundCapacity: max(0, 12 - playerCount),
                players: state.players.enumerated().map { index, player in
                    SetupPlayer(
                        id: player.id,
                        color: PlayerColor.allCases[index % PlayerColor.allCases.count],
                        hand: player.hand.map { CardInstance(id: $0, definitionID: $0) },
                        privateBottomDiscard: nil,
                        industryStacks: [],
                        cash: 0,
                        incomePosition: 0,
                        victoryPoints: 0,
                        spent: 0
                    )
                },
                playerOrder: state.players.map(\.id),
                activePlayerID: state.activePlayerID,
                standardDrawDeck: [],
                wildLocationPool: [],
                wildIndustryPool: [],
                publicDiscard: state.discardPile.map { CardInstance(id: $0, definitionID: $0) },
                boardIndustryPlacements: [],
                placedLinks: [],
                coalMarket: .init(resource: .coal, slots: []),
                ironMarket: .init(resource: .iron, slots: []),
                publicSupply: .init(coal: 0, iron: 0, beer: 0, mayUseSubstitutes: true),
                merchants: [],
                authoritativeVersion: state.authoritativeVersion
            )
        }
    }

    nonisolated enum HostEngineBridgeError: Error, Equatable, Sendable {
        case missingActivePlayer
        case missingReconnectToken(PlayerID)
    }

    nonisolated struct SetupEvent: Codable, Equatable, Sendable {
        enum Payload: Codable, Equatable, Sendable {
            case gameCreated(
                rulesetVersion: String,
                seed: UInt64,
                playerCount: Int
            )
            case turnStateInitialized(
                era: Era,
                roundNumber: Int,
                actionsRemaining: Int,
                turnsCompletedInRound: Int,
                actionNumber: Int,
                canalRoundCapacity: Int,
                railRoundCapacity: Int,
                authoritativeVersion: AuthoritativeVersion
            )
            case playerPrepared(SetupPlayer)
            case wildPoolsPrepared(location: [CardInstance], industry: [CardInstance])
            case deckShuffled([CardInstance])
            case playerOrderDetermined([PlayerID])
            case cardDealt(playerID: PlayerID, card: CardInstance)
            case bottomCardDiscarded(playerID: PlayerID, card: CardInstance)
            case boardInitialized(
                industryPlacements: [BoardIndustryPlacement],
                links: [PlacedLink]
            )
            case publicDiscardInitialized([CardInstance])
            case marketsOpened(coal: ResourceMarket, iron: ResourceMarket)
            case publicSupplyPrepared(PublicSupply)
            case merchantTilesShuffled([String])
            case merchantPlaced(MerchantPlacement)
            case setupCompleted
        }

        var sequence: Int
        var payload: Payload
    }

    nonisolated struct SetupResult: Codable, Equatable, Sendable {
        var state: GameState
        var events: [SetupEvent]
    }
}

extension GameCore.GameState {
    private nonisolated enum CodingKeys: String, CodingKey {
        case rulesetVersion, gameVariant, seed, playerCount, era, roundNumber, actionsRemaining
        case turnsCompletedInRound, actionNumber, canalRoundCapacity, railRoundCapacity
        case players, playerOrder, activePlayerID, standardDrawDeck, wildLocationPool
        case wildIndustryPool, publicDiscard, boardIndustryPlacements, placedLinks
        case coalMarket, ironMarket, publicSupply, merchants, authoritativeVersion
        case turnPhase, roundIncomeCursor, authorityCompleteness, appliedResourceActionIDs
        case finalStandings
    }

    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rulesetVersion = try values.decode(String.self, forKey: .rulesetVersion)
        gameVariant = try values.decodeIfPresent(GameCore.GameVariant.self, forKey: .gameVariant)
        seed = try values.decode(UInt64.self, forKey: .seed)
        playerCount = try values.decode(Int.self, forKey: .playerCount)
        era = try values.decode(GameCore.Era.self, forKey: .era)
        roundNumber = try values.decode(Int.self, forKey: .roundNumber)
        actionsRemaining = try values.decode(Int.self, forKey: .actionsRemaining)
        turnsCompletedInRound = try values.decode(Int.self, forKey: .turnsCompletedInRound)
        actionNumber = try values.decode(Int.self, forKey: .actionNumber)
        canalRoundCapacity = try values.decode(Int.self, forKey: .canalRoundCapacity)
        railRoundCapacity = try values.decode(Int.self, forKey: .railRoundCapacity)
        players = try values.decode([GameCore.SetupPlayer].self, forKey: .players)
        playerOrder = try values.decode([GameCore.PlayerID].self, forKey: .playerOrder)
        activePlayerID = try values.decodeIfPresent(GameCore.PlayerID.self, forKey: .activePlayerID)
        standardDrawDeck = try values.decode([GameCore.CardInstance].self, forKey: .standardDrawDeck)
        wildLocationPool = try values.decode([GameCore.CardInstance].self, forKey: .wildLocationPool)
        wildIndustryPool = try values.decode([GameCore.CardInstance].self, forKey: .wildIndustryPool)
        publicDiscard = try values.decode([GameCore.CardInstance].self, forKey: .publicDiscard)
        boardIndustryPlacements = try values.decode(
            [GameCore.BoardIndustryPlacement].self, forKey: .boardIndustryPlacements
        )
        placedLinks = try values.decode([GameCore.PlacedLink].self, forKey: .placedLinks)
        coalMarket = try values.decode(GameCore.ResourceMarket.self, forKey: .coalMarket)
        ironMarket = try values.decode(GameCore.ResourceMarket.self, forKey: .ironMarket)
        publicSupply = try values.decode(GameCore.PublicSupply.self, forKey: .publicSupply)
        merchants = try values.decode([GameCore.MerchantPlacement].self, forKey: .merchants)
        authoritativeVersion = try values.decode(
            GameCore.AuthoritativeVersion.self, forKey: .authoritativeVersion
        )
        turnPhase = try values.decodeIfPresent(GameCore.TurnPhase.self, forKey: .turnPhase) ?? .active
        roundIncomeCursor = try values.decodeIfPresent(Int.self, forKey: .roundIncomeCursor)
        authorityCompleteness = try values.decodeIfPresent(
            GameCore.AuthorityCompleteness.self, forKey: .authorityCompleteness
        )
        appliedResourceActionIDs = try values.decodeIfPresent(
            [String].self, forKey: .appliedResourceActionIDs
        )
        finalStandings = try values.decodeIfPresent(
            [[GameCore.PlayerID]].self, forKey: .finalStandings
        )
    }
}
