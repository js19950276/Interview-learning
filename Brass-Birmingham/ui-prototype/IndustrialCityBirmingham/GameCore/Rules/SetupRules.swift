import Foundation

extension GameCore {
    nonisolated enum SetupError: Error, Equatable, Sendable {
        case unsupportedPlayerCount(Int)
        case duplicatePlayerIDs
        case insufficientCards
        case invalidCatalogCardCount(expected: Int, actual: Int)
        case invalidMerchantCardinality(expected: Int, tiles: Int, slots: Int)
        case invalidReplay(SetupReplayError)
    }

    nonisolated enum SetupReplayError: String, Codable, Equatable, Error, Sendable {
        case invalidSequence
        case unexpectedPhase
        case invalidPlayerCount
        case invalidPlayer
        case invalidIndustryStacks
        case invalidWildPools
        case invalidDeck
        case invalidPlayerOrder
        case invalidDeal
        case invalidBottomDiscard
        case invalidBoard
        case invalidPublicDiscard
        case invalidMarkets
        case invalidMerchantTiles
        case invalidMerchantPlacement
        case invalidPublicSupply
        case incompleteSetup
    }

    nonisolated struct SetupRules: Sendable {
        private var generator: SeededGenerator

        init(seed: UInt64) {
            generator = SeededGenerator(seed: seed)
        }

        mutating func makeGame(
            catalog verifiedCatalog: VerifiedGameDataCatalog,
            playerIDs: [PlayerID]
        ) throws -> SetupResult {
            let catalog = verifiedCatalog.catalog
            guard (2...4).contains(playerIDs.count) else {
                throw SetupError.unsupportedPlayerCount(playerIDs.count)
            }
            guard Set(playerIDs).count == playerIDs.count else {
                throw SetupError.duplicatePlayerIDs
            }

            let playerCount = playerIDs.count
            let roundCapacity = 12 - playerCount
            let preparedPlayers = playerIDs.enumerated().map { index, playerID in
                SetupPlayer(
                    id: playerID,
                    color: PlayerColor.allCases[index],
                    hand: [],
                    privateBottomDiscard: nil,
                    industryStacks: Self.industryStacks(
                        catalog.industries,
                        color: PlayerColor.allCases[index]
                    ),
                    cash: 17,
                    incomePosition: 10,
                    victoryPoints: 0,
                    spent: 0
                )
            }

            let standardDefinitions = catalog.cards.filter {
                $0.playerCounts.contains(playerCount)
                    && $0.kind != .wildLocation
                    && $0.kind != .wildIndustry
            }
            var deck = Self.cardInstances(standardDefinitions)
            let expectedDeckCount = Self.standardDeckCount(for: playerCount)
            guard deck.count == expectedDeckCount else {
                throw SetupError.invalidCatalogCardCount(
                    expected: expectedDeckCount,
                    actual: deck.count
                )
            }
            generator.shuffle(&deck)

            let wildLocationPool = Self.cardInstances(catalog.cards.filter { $0.kind == .wildLocation })
            let wildIndustryPool = Self.cardInstances(catalog.cards.filter { $0.kind == .wildIndustry })

            var playerOrder = playerIDs
            generator.shuffle(&playerOrder)
            guard deck.count >= playerCount * 9 else {
                throw SetupError.insufficientCards
            }

            var events: [SetupEvent] = []
            append(
                .gameCreated(
                    rulesetVersion: catalog.rulesetVersion,
                    seed: generator.seed,
                    playerCount: playerCount
                ),
                to: &events
            )
            append(
                .turnStateInitialized(
                    era: .canal,
                    roundNumber: 1,
                    actionsRemaining: 1,
                    turnsCompletedInRound: 0,
                    actionNumber: 0,
                    canalRoundCapacity: roundCapacity,
                    railRoundCapacity: roundCapacity,
                    authoritativeVersion: .init(rawValue: 0)
                ),
                to: &events
            )
            for player in preparedPlayers {
                append(.playerPrepared(player), to: &events)
            }
            append(
                .wildPoolsPrepared(location: wildLocationPool, industry: wildIndustryPool),
                to: &events
            )
            append(.deckShuffled(deck), to: &events)
            append(.playerOrderDetermined(playerOrder), to: &events)

            for _ in 0..<8 {
                for playerID in playerOrder {
                    append(.cardDealt(playerID: playerID, card: deck.removeFirst()), to: &events)
                }
            }
            for playerID in playerOrder {
                append(
                    .bottomCardDiscarded(playerID: playerID, card: deck.removeFirst()),
                    to: &events
                )
            }

            append(.boardInitialized(industryPlacements: [], links: []), to: &events)
            append(.publicDiscardInitialized([]), to: &events)
            append(.marketsOpened(coal: coalMarket(), iron: ironMarket()), to: &events)

            let merchantByID = Dictionary(uniqueKeysWithValues: catalog.merchants.map { ($0.id, $0) })
            var merchantTiles = catalog.merchants
                .filter { $0.playerCounts.contains(playerCount) }
                .flatMap { definition in Array(repeating: definition.id, count: definition.count) }
            let merchantSlots = catalog.board.merchantSlots.filter { $0.playerCounts.contains(playerCount) }
            let expectedMerchantCount = playerCount * 2 + 1
            guard merchantTiles.count == expectedMerchantCount,
                  merchantSlots.count == expectedMerchantCount,
                  merchantTiles.count == merchantSlots.count
            else {
                throw SetupError.invalidMerchantCardinality(
                    expected: expectedMerchantCount,
                    tiles: merchantTiles.count,
                    slots: merchantSlots.count
                )
            }
            generator.shuffle(&merchantTiles)
            append(.merchantTilesShuffled(merchantTiles), to: &events)
            var merchantBeer = 0
            for (slot, merchantID) in zip(merchantSlots, merchantTiles) {
                let hasBeer = merchantByID[merchantID]?.acceptedIndustryIDs.isEmpty == false
                if hasBeer { merchantBeer += 1 }
                append(
                    .merchantPlaced(
                        MerchantPlacement(
                            slotID: slot.id,
                            merchantDefinitionID: merchantID,
                            hasBeer: hasBeer
                        )
                    ),
                    to: &events
                )
            }
            append(
                .publicSupplyPrepared(
                    PublicSupply(
                        coal: 17,
                        iron: 10,
                        beer: 15 - merchantBeer,
                        mayUseSubstitutes: true
                    )
                ),
                to: &events
            )
            append(.setupCompleted, to: &events)

            return SetupResult(
                state: try Self.replay(events, catalog: verifiedCatalog),
                events: events
            )
        }

        static func replay(
            _ events: [SetupEvent],
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> GameState {
            let catalog = verifiedCatalog.catalog
            enum Phase {
                case gameCreated
                case turnState
                case players
                case wildPools
                case deck
                case playerOrder
                case deal
                case bottomDiscard
                case board
                case publicDiscard
                case markets
                case merchantTiles
                case merchants
                case publicSupply
                case completed
            }

            var phase = Phase.gameCreated
            var state: GameState?
            var pendingMerchants: [String] = []
            var expectedPlayerCount = 0
            var expectedMerchantCount = 0
            var expectedMerchantSlots: Set<String> = []
            let merchantsByID = Dictionary(uniqueKeysWithValues: catalog.merchants.map { ($0.id, $0) })
            var dealIndex = 0
            var bottomDiscardIndex = 0

            for (expectedSequence, event) in events.enumerated() {
                guard event.sequence == expectedSequence else {
                    throw SetupError.invalidReplay(.invalidSequence)
                }

                switch event.payload {
                case let .gameCreated(
                    rulesetVersion,
                    seed,
                    playerCount
                ):
                    guard phase == .gameCreated,
                          rulesetVersion == catalog.rulesetVersion,
                          (2...4).contains(playerCount)
                    else {
                        throw SetupError.invalidReplay(
                            phase == .gameCreated ? .invalidPlayerCount : .unexpectedPhase
                        )
                    }
                    expectedPlayerCount = playerCount
                    expectedMerchantCount = playerCount * 2 + 1
                    expectedMerchantSlots = Set(catalog.board.merchantSlots
                        .filter { $0.playerCounts.contains(playerCount) }
                        .map(\.id))
                    state = GameState(
                        rulesetVersion: rulesetVersion,
                        seed: seed,
                        playerCount: playerCount,
                        era: .canal,
                        roundNumber: 0,
                        actionsRemaining: 0,
                        turnsCompletedInRound: 0,
                        actionNumber: 0,
                        canalRoundCapacity: 0,
                        railRoundCapacity: 0,
                        players: [],
                        playerOrder: [],
                        activePlayerID: nil,
                        standardDrawDeck: [],
                        wildLocationPool: [],
                        wildIndustryPool: [],
                        publicDiscard: [],
                        boardIndustryPlacements: [],
                        placedLinks: [],
                        coalMarket: ResourceMarket(resource: .coal, slots: []),
                        ironMarket: ResourceMarket(resource: .iron, slots: []),
                        publicSupply: PublicSupply(coal: 0, iron: 0, beer: 0, mayUseSubstitutes: true),
                        merchants: [],
                        authoritativeVersion: .init(rawValue: 0)
                    )
                    phase = .turnState

                case let .turnStateInitialized(
                    era,
                    roundNumber,
                    actionsRemaining,
                    turnsCompletedInRound,
                    actionNumber,
                    canalRoundCapacity,
                    railRoundCapacity,
                    authoritativeVersion
                ):
                    guard phase == .turnState, var value = state else {
                        throw SetupError.invalidReplay(.unexpectedPhase)
                    }
                    let expectedCapacity = 12 - expectedPlayerCount
                    guard era == .canal,
                          roundNumber == 1,
                          actionsRemaining == 1,
                          turnsCompletedInRound == 0,
                          actionNumber == 0,
                          canalRoundCapacity == expectedCapacity,
                          railRoundCapacity == expectedCapacity,
                          authoritativeVersion == .init(rawValue: 0)
                    else {
                        throw SetupError.invalidReplay(.unexpectedPhase)
                    }
                    value.era = era
                    value.roundNumber = roundNumber
                    value.actionsRemaining = actionsRemaining
                    value.turnsCompletedInRound = turnsCompletedInRound
                    value.actionNumber = actionNumber
                    value.canalRoundCapacity = canalRoundCapacity
                    value.railRoundCapacity = railRoundCapacity
                    value.authoritativeVersion = authoritativeVersion
                    state = value
                    phase = .players

                case let .playerPrepared(player):
                    guard phase == .players, var value = state,
                          value.players.count < expectedPlayerCount,
                          value.players.contains(where: { $0.id == player.id }) == false,
                          player.hand.isEmpty,
                          player.privateBottomDiscard == nil,
                          player.cash == 17,
                          player.incomePosition == 10,
                          player.victoryPoints == 0,
                          player.spent == 0,
                          value.players.contains(where: { $0.color == player.color }) == false
                    else {
                        throw SetupError.invalidReplay(.invalidPlayer)
                    }
                    guard player.industryStacks == industryStacks(
                        catalog.industries,
                        color: player.color
                    ) else {
                        throw SetupError.invalidReplay(.invalidIndustryStacks)
                    }
                    value.players.append(player)
                    state = value
                    if value.players.count == expectedPlayerCount { phase = .wildPools }

                case let .wildPoolsPrepared(location, industry):
                    let expectedLocation = cardInstances(catalog.cards.filter { $0.kind == .wildLocation })
                    let expectedIndustry = cardInstances(catalog.cards.filter { $0.kind == .wildIndustry })
                    guard phase == .wildPools,
                          location == expectedLocation,
                          industry == expectedIndustry
                    else {
                        throw SetupError.invalidReplay(.invalidWildPools)
                    }
                    state?.wildLocationPool = location
                    state?.wildIndustryPool = industry
                    phase = .deck

                case let .deckShuffled(cards):
                    let expectedCards = cardInstances(catalog.cards.filter {
                        $0.playerCounts.contains(expectedPlayerCount)
                            && $0.kind != .wildLocation
                            && $0.kind != .wildIndustry
                    })
                    guard phase == .deck,
                          cards.count == standardDeckCount(for: expectedPlayerCount),
                          Set(cards) == Set(expectedCards)
                    else {
                        throw SetupError.invalidReplay(.invalidDeck)
                    }
                    state?.standardDrawDeck = cards
                    phase = .playerOrder

                case let .playerOrderDetermined(playerOrder):
                    guard phase == .playerOrder, var value = state,
                          playerOrder.count == expectedPlayerCount,
                          Set(playerOrder).count == expectedPlayerCount,
                          Set(value.players.map(\.id)) == Set(playerOrder),
                          let activePlayerID = playerOrder.first
                    else {
                        throw SetupError.invalidReplay(.invalidPlayerOrder)
                    }
                    let playersByID = Dictionary(uniqueKeysWithValues: value.players.map { ($0.id, $0) })
                    value.players = try playerOrder.map {
                        guard let player = playersByID[$0] else {
                            throw SetupError.invalidReplay(.invalidPlayerOrder)
                        }
                        return player
                    }
                    value.playerOrder = playerOrder
                    value.activePlayerID = activePlayerID
                    state = value
                    phase = .deal

                case let .cardDealt(playerID, card):
                    guard phase == .deal, var value = state,
                          dealIndex < expectedPlayerCount * 8,
                          playerID == value.playerOrder[dealIndex % expectedPlayerCount],
                          value.standardDrawDeck.first == card,
                          let playerIndex = value.players.firstIndex(where: { $0.id == playerID })
                    else {
                        throw SetupError.invalidReplay(.invalidDeal)
                    }
                    value.standardDrawDeck.removeFirst()
                    value.players[playerIndex].hand.append(card)
                    state = value
                    dealIndex += 1
                    if dealIndex == expectedPlayerCount * 8 { phase = .bottomDiscard }

                case let .bottomCardDiscarded(playerID, card):
                    guard phase == .bottomDiscard, var value = state,
                          bottomDiscardIndex < expectedPlayerCount,
                          playerID == value.playerOrder[bottomDiscardIndex],
                          value.standardDrawDeck.first == card,
                          let playerIndex = value.players.firstIndex(where: { $0.id == playerID }),
                          value.players[playerIndex].privateBottomDiscard == nil
                    else {
                        throw SetupError.invalidReplay(.invalidBottomDiscard)
                    }
                    value.standardDrawDeck.removeFirst()
                    value.players[playerIndex].privateBottomDiscard = card
                    state = value
                    bottomDiscardIndex += 1
                    if bottomDiscardIndex == expectedPlayerCount { phase = .board }

                case let .boardInitialized(industryPlacements, links):
                    guard phase == .board, industryPlacements.isEmpty, links.isEmpty else {
                        throw SetupError.invalidReplay(.invalidBoard)
                    }
                    state?.boardIndustryPlacements = industryPlacements
                    state?.placedLinks = links
                    phase = .publicDiscard

                case let .publicDiscardInitialized(cards):
                    guard phase == .publicDiscard, cards.isEmpty else {
                        throw SetupError.invalidReplay(.invalidPublicDiscard)
                    }
                    state?.publicDiscard = cards
                    phase = .markets

                case let .marketsOpened(coal, iron):
                    guard phase == .markets, validMarkets(coal: coal, iron: iron) else {
                        throw SetupError.invalidReplay(.invalidMarkets)
                    }
                    state?.coalMarket = coal
                    state?.ironMarket = iron
                    phase = .merchantTiles

                case let .publicSupplyPrepared(supply):
                    guard phase == .publicSupply,
                          supply.coal == 17,
                          supply.iron == 10,
                          supply.beer == 15 - (state?.merchants.filter(\.hasBeer).count ?? 0),
                          supply.mayUseSubstitutes
                    else {
                        throw SetupError.invalidReplay(.invalidPublicSupply)
                    }
                    state?.publicSupply = supply
                    phase = .completed

                case let .merchantTilesShuffled(merchantIDs):
                    let expectedMerchantIDs = catalog.merchants
                        .filter { $0.playerCounts.contains(expectedPlayerCount) }
                        .flatMap { Array(repeating: $0.id, count: $0.count) }
                        .sorted()
                    guard phase == .merchantTiles,
                          merchantIDs.count == expectedMerchantCount,
                          merchantIDs.sorted() == expectedMerchantIDs
                    else {
                        throw SetupError.invalidReplay(.invalidMerchantTiles)
                    }
                    pendingMerchants = merchantIDs
                    phase = .merchants

                case let .merchantPlaced(placement):
                    guard phase == .merchants, var value = state,
                          pendingMerchants.first == placement.merchantDefinitionID,
                          expectedMerchantSlots.contains(placement.slotID),
                          value.merchants.contains(where: { $0.slotID == placement.slotID }) == false,
                          let merchant = merchantsByID[placement.merchantDefinitionID],
                          merchant.playerCounts.contains(expectedPlayerCount),
                          placement.hasBeer == (merchant.acceptedIndustryIDs.isEmpty == false)
                    else {
                        throw SetupError.invalidReplay(.invalidMerchantPlacement)
                    }
                    pendingMerchants.removeFirst()
                    value.merchants.append(placement)
                    state = value
                    if value.merchants.count == expectedMerchantCount { phase = .publicSupply }

                case .setupCompleted:
                    guard phase == .completed,
                          event.sequence == events.count - 1,
                          var value = state,
                          pendingMerchants.isEmpty,
                          value.players.count == expectedPlayerCount,
                          value.players.allSatisfy({
                              $0.hand.count == 8 && $0.privateBottomDiscard != nil
                          }),
                          value.playerOrder.count == expectedPlayerCount,
                          Set(value.players.map(\.color)).count == expectedPlayerCount,
                          value.merchants.count == expectedMerchantCount,
                          Set(value.merchants.map(\.slotID)) == expectedMerchantSlots
                    else {
                        throw SetupError.invalidReplay(.incompleteSetup)
                    }
                    value.authorityCompleteness = .complete
                    value.appliedResourceActionIDs = []
                    return value
                }
            }

            throw SetupError.invalidReplay(.incompleteSetup)
        }

        private static func standardDeckCount(for playerCount: Int) -> Int {
            [2: 40, 3: 54, 4: 64][playerCount] ?? 0
        }

        private static func validIndustryStacks(_ stacks: [IndustryStack]) -> Bool {
            guard stacks.count == 6,
                  Set(stacks.map(\.industryDefinitionID)).count == stacks.count
            else { return false }
            return stacks.allSatisfy { stack in
                stack.tiles.isEmpty == false
                    && stack.tiles.allSatisfy { $0.industryDefinitionID == stack.industryDefinitionID }
                    && stack.tiles.map(\.level) == stack.tiles.map(\.level).sorted()
            }
        }

        private static func validMarkets(coal: ResourceMarket, iron: ResourceMarket) -> Bool {
            coal == ResourceMarket(
                resource: .coal,
                slots: (1...7).flatMap { price in
                    Array(repeating: MarketSlot(price: price, hasCube: true), count: 2)
                }.enumerated().map { index, slot in
                    MarketSlot(price: slot.price, hasCube: index != 0)
                }
            ) && iron == ResourceMarket(
                resource: .iron,
                slots: ResourceMarket.officialIronPrices.enumerated().map { index, price in
                    MarketSlot(price: price, hasCube: index >= 2)
                }
            )
        }

        private static func cardInstances(_ definitions: [CardDefinition]) -> [CardInstance] {
            definitions.flatMap { definition in
                (1...definition.count).map {
                    CardInstance(id: "\(definition.id)-\($0)", definitionID: definition.id)
                }
            }
        }

        private static func industryStacks(
            _ definitions: [IndustryDefinition],
            color: PlayerColor
        ) -> [IndustryStack] {
            definitions.map { definition in
                var tiles: [IndustryTile] = []
                for level in definition.levels.sorted(by: { $0.level < $1.level }) {
                    for copy in 1...level.copiesPerColor {
                        tiles.append(
                            IndustryTile(
                                id: "\(color.rawValue)-\(definition.id)-\(level.level)-\(copy)",
                                industryDefinitionID: definition.id,
                                level: level.level
                            )
                        )
                    }
                }
                return IndustryStack(industryDefinitionID: definition.id, tiles: tiles)
            }
        }

        private func coalMarket() -> ResourceMarket {
            let prices = (1...7).flatMap { Array(repeating: $0, count: 2) }
            return ResourceMarket(
                resource: .coal,
                slots: prices.enumerated().map { index, price in
                    MarketSlot(price: price, hasCube: index != 0)
                }
            )
        }

        private func ironMarket() -> ResourceMarket {
            return ResourceMarket(
                resource: .iron,
                slots: ResourceMarket.officialIronPrices.enumerated().map { index, price in
                    MarketSlot(price: price, hasCube: index >= 2)
                }
            )
        }

        private func append(_ payload: SetupEvent.Payload, to events: inout [SetupEvent]) {
            events.append(.init(sequence: events.count, payload: payload))
        }
    }

    nonisolated struct SeededGenerator: RandomNumberGenerator, Sendable {
        let seed: UInt64
        private var state: UInt64

        init(seed: UInt64) {
            self.seed = seed
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }

        mutating func shuffle<Element>(_ values: inout [Element]) {
            guard values.count > 1 else { return }
            for upperBound in stride(from: values.count - 1, through: 1, by: -1) {
                let selected = Int(nextIndex(upperBound: UInt64(upperBound + 1)))
                if selected != upperBound {
                    values.swapAt(selected, upperBound)
                }
            }
        }

        mutating func nextIndex(upperBound: UInt64) -> UInt64 {
            Self.boundedIndex(upperBound: upperBound) { next() }
        }

        static func boundedIndex(
            upperBound: UInt64,
            next: () -> UInt64
        ) -> UInt64 {
            precondition(upperBound > 0)
            let rejectionThreshold = (0 &- upperBound) % upperBound
            while true {
                let value = next()
                if value >= rejectionThreshold { return value % upperBound }
            }
        }
    }
}
