import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct GameSetupTests {
    @Test func twoPlayerSetupUsesTheOfficialStartingShape() throws {
        try verifySetup(playerCount: 2, seed: 2001, roundCapacity: 10)
    }

    @Test func threePlayerSetupUsesTheOfficialStartingShape() throws {
        try verifySetup(playerCount: 3, seed: 3001, roundCapacity: 9)
    }

    @Test func fourPlayerSetupUsesTheOfficialStartingShape() throws {
        try verifySetup(playerCount: 4, seed: 4001, roundCapacity: 8)
    }

    @Test func identicalSeedsProduceIdenticalCanonicalStateAndReplay() throws {
        let catalog = completeCatalog()
        let players = playerIDs(count: 4)
        var firstRules = GameCore.SetupRules(seed: 4001)
        var secondRules = GameCore.SetupRules(seed: 4001)

        let verifiedCatalog = verifiedCatalog(catalog)
        let first = try firstRules.makeGame(catalog: verifiedCatalog, playerIDs: players)
        let second = try secondRules.makeGame(catalog: verifiedCatalog, playerIDs: players)

        #expect(first == second)
        #expect(try first.state.canonicalBytes() == second.state.canonicalBytes())
        #expect(try first.state.canonicalHash() == second.state.canonicalHash())
        #expect(try GameCore.SetupRules.replay(first.events, catalog: verifiedCatalog) == first.state)
    }

    @Test func setupConsumesTheShuffledDeckInDealThenBottomDiscardOrder() throws {
        let catalog = completeCatalog()
        let players = playerIDs(count: 3)
        var rules = GameCore.SetupRules(seed: 3001)

        let result = try rules.makeGame(catalog: verifiedCatalog(catalog), playerIDs: players)
        let shuffledDeck = try #require(result.events.compactMap { event in
            if case .deckShuffled(let cards) = event.payload { cards } else { nil }
        }.first)
        let dealtCards = result.events.compactMap { event in
            if case .cardDealt(playerID: _, card: let card) = event.payload { card } else { nil }
        }
        let bottomCards = result.events.compactMap { event in
            if case .bottomCardDiscarded(_, let card) = event.payload { card } else { nil }
        }

        #expect(dealtCards + bottomCards == Array(shuffledDeck.prefix(players.count * 9)))
    }

    @Test func seededGeneratorRejectsBiasedUInt64ValuesBeforeBounding() {
        var values = [UInt64(0), UInt64.max]

        let index = GameCore.SeededGenerator.boundedIndex(upperBound: 3) {
            values.removeFirst()
        }

        #expect(index == 0)
        #expect(values.isEmpty)
    }

    @Test func replayEventsExplicitlyInitializeEverySetupStateSurface() throws {
        let catalog = completeCatalog()
        var rules = GameCore.SetupRules(seed: 2001)

        let result = try rules.makeGame(
            catalog: verifiedCatalog(catalog),
            playerIDs: playerIDs(count: 2)
        )

        #expect(result.events.contains { if case .gameCreated = $0.payload { true } else { false } })
        #expect(result.events.contains { if case .turnStateInitialized = $0.payload { true } else { false } })
        #expect(result.events.contains { if case .playerPrepared = $0.payload { true } else { false } })
        #expect(result.events.contains { if case .wildPoolsPrepared = $0.payload { true } else { false } })
        #expect(result.events.contains { if case .deckShuffled = $0.payload { true } else { false } })
        #expect(result.events.contains { if case .playerOrderDetermined = $0.payload { true } else { false } })
        #expect(result.events.contains { if case .cardDealt = $0.payload { true } else { false } })
        #expect(result.events.contains { if case .bottomCardDiscarded = $0.payload { true } else { false } })
        #expect(result.events.contains { if case .boardInitialized = $0.payload { true } else { false } })
        #expect(result.events.contains { if case .publicDiscardInitialized = $0.payload { true } else { false } })
        #expect(result.events.contains { if case .marketsOpened = $0.payload { true } else { false } })
        #expect(result.events.contains { if case .publicSupplyPrepared = $0.payload { true } else { false } })
        #expect(result.events.contains { if case .merchantPlaced = $0.payload { true } else { false } })
        #expect(try GameCore.SetupRules.replay(
            result.events,
            catalog: verifiedCatalog(catalog)
        ) == result.state)
    }

    @Test func replayRejectsMissingDuplicateAndOutOfOrderSetupPhases() throws {
        let result = try setupResult(playerCount: 2, seed: 2001)

        let onlyBookends = [
            GameCore.SetupEvent(sequence: 0, payload: result.events[0].payload),
            GameCore.SetupEvent(sequence: 1, payload: .setupCompleted),
        ]
        #expect(replayError(onlyBookends) == .incompleteSetup)

        var duplicated = result.events
        let turnEvent = try #require(duplicated.first { event in
            if case .turnStateInitialized = event.payload { true } else { false }
        })
        duplicated.insert(turnEvent, at: turnEvent.sequence + 1)
        duplicated = resequenced(duplicated)
        #expect(replayError(duplicated) == .unexpectedPhase)

        var reordered = result.events
        let boardIndex = try #require(reordered.firstIndex { event in
            if case .boardInitialized = event.payload { true } else { false }
        })
        let marketsIndex = try #require(reordered.firstIndex { event in
            if case .marketsOpened = event.payload { true } else { false }
        })
        reordered.swapAt(boardIndex, marketsIndex)
        reordered = resequenced(reordered)
        #expect(replayError(reordered) == .invalidMarkets)
    }

    @Test func replayRejectsTamperedSetupPayloads() throws {
        let original = try setupResult(playerCount: 2, seed: 2001)
        let mutations: [(String, GameCore.SetupReplayError, (inout [GameCore.SetupEvent]) throws -> Void)] = [
            ("player count", .invalidPlayerCount, { events in
                let index = try #require(events.firstIndex { if case .gameCreated = $0.payload { true } else { false } })
                guard case let .gameCreated(rulesetVersion, seed, _) = events[index].payload else { return }
                events[index].payload = .gameCreated(rulesetVersion: rulesetVersion, seed: seed, playerCount: 5)
            }),
            ("prepared hand", .invalidPlayer, { events in
                let index = try #require(events.firstIndex { if case .playerPrepared = $0.payload { true } else { false } })
                guard case var .playerPrepared(player) = events[index].payload else { return }
                player.hand = [.init(id: "injected", definitionID: "injected")]
                events[index].payload = .playerPrepared(player)
            }),
            ("industry stack", .invalidIndustryStacks, { events in
                let index = try #require(events.firstIndex { if case .playerPrepared = $0.payload { true } else { false } })
                guard case var .playerPrepared(player) = events[index].payload else { return }
                player.industryStacks.removeLast()
                events[index].payload = .playerPrepared(player)
            }),
            ("bottom discard", .invalidBottomDiscard, { events in
                let indices = events.indices.filter { if case .bottomCardDiscarded = events[$0].payload { true } else { false } }
                guard indices.count >= 2,
                      case let .bottomCardDiscarded(_, card) = events[indices[0]].payload,
                      case let .bottomCardDiscarded(secondPlayer, _) = events[indices[1]].payload
                else { return }
                events[indices[0]].payload = .bottomCardDiscarded(playerID: secondPlayer, card: card)
            }),
            ("player order", .invalidPlayerOrder, { events in
                let index = try #require(events.firstIndex { if case .playerOrderDetermined = $0.payload { true } else { false } })
                guard case let .playerOrderDetermined(order) = events[index].payload else { return }
                events[index].payload = .playerOrderDetermined([order[0], order[0]])
            }),
            ("market", .invalidMarkets, { events in
                let index = try #require(events.firstIndex { if case .marketsOpened = $0.payload { true } else { false } })
                guard case let .marketsOpened(coal, iron) = events[index].payload else { return }
                events[index].payload = .marketsOpened(
                    coal: .init(resource: .coal, slots: Array(coal.slots.dropFirst())),
                    iron: iron
                )
            }),
            ("merchant", .invalidMerchantPlacement, { events in
                let indices = events.indices.filter { if case .merchantPlaced = events[$0].payload { true } else { false } }
                guard indices.count >= 2,
                      case let .merchantPlaced(first) = events[indices[0]].payload,
                      case var .merchantPlaced(second) = events[indices[1]].payload
                else { return }
                second.slotID = first.slotID
                events[indices[1]].payload = .merchantPlaced(second)
            }),
            ("public supply", .invalidPublicSupply, { events in
                let index = try #require(events.firstIndex { if case .publicSupplyPrepared = $0.payload { true } else { false } })
                events[index].payload = .publicSupplyPrepared(.init(coal: -1, iron: 10, beer: 15, mayUseSubstitutes: true))
            }),
        ]

        for (name, expectedError, mutate) in mutations {
            var events = original.events
            try mutate(&events)
            #expect(replayError(events) == expectedError, "Expected stable replay rejection for \(name)")
        }
    }

    @Test func replayUsesVerifiedCatalogToRejectAuthenticLookingForgeries() throws {
        let catalog = completeCatalog()
        let verified = verifiedCatalog(catalog)
        let original = try setupResult(playerCount: 2, seed: 2001)
        let mutations: [(GameCore.SetupReplayError, (inout [GameCore.SetupEvent]) throws -> Void)] = [
            (.invalidPlayer, { events in
                let indices = events.indices.filter { if case .playerPrepared = events[$0].payload { true } else { false } }
                guard indices.count == 2,
                      case let .playerPrepared(first) = events[indices[0]].payload,
                      case var .playerPrepared(second) = events[indices[1]].payload
                else { return }
                second.color = first.color
                events[indices[1]].payload = .playerPrepared(second)
            }),
            (.invalidWildPools, { events in
                let index = try #require(events.firstIndex { if case .wildPoolsPrepared = $0.payload { true } else { false } })
                guard case let .wildPoolsPrepared(location, industry) = events[index].payload,
                      let first = location.first
                else { return }
                events[index].payload = .wildPoolsPrepared(
                    location: Array(repeating: first, count: 4),
                    industry: industry
                )
            }),
            (.invalidIndustryStacks, { events in
                let index = try #require(events.firstIndex { if case .playerPrepared = $0.payload { true } else { false } })
                guard case var .playerPrepared(player) = events[index].payload else { return }
                player.industryStacks[0].tiles[0].id = "forged-tile"
                events[index].payload = .playerPrepared(player)
            }),
            (.invalidMerchantTiles, { events in
                let shuffledIndex = try #require(events.firstIndex { if case .merchantTilesShuffled = $0.payload { true } else { false } })
                guard case var .merchantTilesShuffled(ids) = events[shuffledIndex].payload else { return }
                let originalID = ids[0]
                ids[0] = "forged-merchant"
                events[shuffledIndex].payload = .merchantTilesShuffled(ids)

                let placementIndex = try #require(events.firstIndex { event in
                    if case .merchantPlaced(let placement) = event.payload {
                        placement.merchantDefinitionID == originalID
                    } else { false }
                })
                guard case var .merchantPlaced(placement) = events[placementIndex].payload else { return }
                placement.merchantDefinitionID = "forged-merchant"
                placement.slotID = "forged-slot"
                placement.hasBeer.toggle()
                events[placementIndex].payload = .merchantPlaced(placement)

                let beerCount = events.reduce(0) { count, event in
                    if case .merchantPlaced(let value) = event.payload, value.hasBeer { count + 1 } else { count }
                }
                let supplyIndex = try #require(events.firstIndex { if case .publicSupplyPrepared = $0.payload { true } else { false } })
                events[supplyIndex].payload = .publicSupplyPrepared(.init(
                    coal: 17,
                    iron: 10,
                    beer: 15 - beerCount,
                    mayUseSubstitutes: true
                ))
            }),
        ]

        for (expected, mutate) in mutations {
            var events = original.events
            try mutate(&events)
            #expect(replayError(events, catalog: verified) == expected)
        }
    }

    @Test func setupStateCreatesTheExistingPassOnlyHostEngineWithoutLosingIdentityOrHands() throws {
        let catalog = completeCatalog()
        let players = playerIDs(count: 3)
        var rules = GameCore.SetupRules(seed: 3001)
        let result = try rules.makeGame(catalog: verifiedCatalog(catalog), playerIDs: players)
        let tokens = Dictionary(uniqueKeysWithValues: players.map {
            ($0, GameCore.ReconnectToken(rawValue: "token-\($0.rawValue)"))
        })

        let engine = try result.state.makeHostEngine(
            roomID: .init(rawValue: "setup-room"),
            reconnectTokens: tokens,
            protocolVersion: 1
        )

        #expect(engine.rulesetVersion == result.state.rulesetVersion)
        #expect(engine.protocolVersion == 1)
        #expect(engine.state.players.map(\.id) == result.state.playerOrder)
        #expect(engine.state.players.map(\.hand) == result.state.players.map {
            $0.hand.map(\.id)
        })
        #expect(engine.state.activePlayerID == result.state.activePlayerID)
        #expect(engine.state.authoritativeVersion == result.state.authoritativeVersion)
        #expect(engine.state.discardPile == result.state.publicDiscard.map(\.id))
    }

    @Test func passMutatesTheSetupGameStateAsTheEnginesOnlyAuthority() throws {
        let result = try setupResult(playerCount: 2, seed: 2001)
        let activePlayerID = try #require(result.state.activePlayerID)
        let activePlayer = try #require(result.state.players.first { $0.id == activePlayerID })
        let discardedCard = try #require(activePlayer.hand.first)
        let tokens = Dictionary(uniqueKeysWithValues: result.state.playerOrder.map {
            ($0, GameCore.ReconnectToken(rawValue: "token-\($0.rawValue)"))
        })
        var engine = try result.state.makeHostEngine(
            roomID: .init(rawValue: "single-authority-room"),
            reconnectTokens: tokens,
            protocolVersion: 1
        )

        let submission = engine.submit(.init(
            protocolVersion: 1,
            rulesetVersion: result.state.rulesetVersion,
            roomID: .init(rawValue: "single-authority-room"),
            senderID: activePlayerID,
            reconnectToken: try #require(tokens[activePlayerID]),
            baseVersion: result.state.authoritativeVersion,
            payload: .pass(.init(cardID: discardedCard.id))
        ), catalog: verifiedCatalog(completeCatalog()))

        guard case .accepted = submission else {
            Issue.record("Expected setup pass to be accepted")
            return
        }
        let mutatedPlayer = try #require(engine.gameState.players.first { $0.id == activePlayerID })
        #expect(mutatedPlayer.hand.count == 8)
        #expect(mutatedPlayer.hand.contains(discardedCard) == false)
        #expect(engine.gameState.publicDiscard == [discardedCard])
        #expect(engine.gameState.activePlayerID == result.state.playerOrder[1])
        #expect(engine.gameState.actionsRemaining == 1)
        #expect(engine.gameState.turnsCompletedInRound == 1)
        #expect(engine.gameState.roundNumber == 1)
        #expect(engine.gameState.actionNumber == 1)
        #expect(engine.gameState.authoritativeVersion == .init(rawValue: 1))
        #expect(engine.state.players.first { $0.id == activePlayerID }?.hand == mutatedPlayer.hand.map(\.id))
        #expect(engine.state.discardPile == engine.gameState.publicDiscard.map(\.id))
    }

    @Test func canalPassesConsumeActionsBeforeAdvancingPlayersAndRounds() throws {
        let result = try setupResult(playerCount: 2, seed: 2001)
        let roomID = GameCore.RoomID(rawValue: "turn-semantics-room")
        let tokens = Dictionary(uniqueKeysWithValues: result.state.playerOrder.map {
            ($0, GameCore.ReconnectToken(rawValue: "token-\($0.rawValue)"))
        })
        var engine = try result.state.makeHostEngine(
            roomID: roomID,
            reconnectTokens: tokens,
            protocolVersion: 1
        )
        let first = result.state.playerOrder[0]
        let second = result.state.playerOrder[1]

        try submitPass(to: &engine, playerID: first, roomID: roomID, tokens: tokens)
        #expect(engine.gameState.activePlayerID == second)
        #expect(engine.gameState.actionsRemaining == 1)
        #expect(engine.gameState.turnsCompletedInRound == 1)
        #expect(engine.gameState.roundNumber == 1)

        try submitPass(to: &engine, playerID: second, roomID: roomID, tokens: tokens)
        #expect(engine.gameState.activePlayerID == first)
        #expect(engine.gameState.actionsRemaining == 2)
        #expect(engine.gameState.turnsCompletedInRound == 0)
        #expect(engine.gameState.roundNumber == 2)

        try submitPass(to: &engine, playerID: first, roomID: roomID, tokens: tokens)
        #expect(engine.gameState.activePlayerID == first)
        #expect(engine.gameState.actionsRemaining == 1)
        #expect(engine.gameState.turnsCompletedInRound == 0)
        #expect(engine.gameState.roundNumber == 2)

        try submitPass(to: &engine, playerID: first, roomID: roomID, tokens: tokens)
        #expect(engine.gameState.activePlayerID == second)
        #expect(engine.gameState.actionsRemaining == 2)
        #expect(engine.gameState.turnsCompletedInRound == 1)
        #expect(engine.gameState.roundNumber == 2)

        try submitPass(to: &engine, playerID: second, roomID: roomID, tokens: tokens)
        #expect(engine.gameState.activePlayerID == second)
        #expect(engine.gameState.actionsRemaining == 1)
        try submitPass(to: &engine, playerID: second, roomID: roomID, tokens: tokens)
        #expect(engine.gameState.activePlayerID == first)
        #expect(engine.gameState.actionsRemaining == 2)
        #expect(engine.gameState.turnsCompletedInRound == 0)
        #expect(engine.gameState.roundNumber == 3)
        #expect(engine.gameState.actionNumber == 6)
        #expect(engine.gameState.authoritativeVersion == .init(rawValue: 6))
        #expect(engine.gameState.publicDiscard.count == 6)
        #expect(engine.gameState.players.allSatisfy { $0.hand.count == 8 })
    }

    @Test func passesAdvanceThroughTheSeededPlayerOrder() throws {
        let result = try setupResult(playerCount: 4, seed: 4001)
        let roomID = GameCore.RoomID(rawValue: "seeded-order-turn")
        let tokens = Dictionary(uniqueKeysWithValues: result.state.playerOrder.map {
            ($0, GameCore.ReconnectToken(rawValue: "token-\($0.rawValue)"))
        })
        var engine = try result.state.makeHostEngine(
            roomID: roomID,
            reconnectTokens: tokens,
            protocolVersion: 1
        )

        try submitPass(
            to: &engine,
            playerID: result.state.playerOrder[0],
            roomID: roomID,
            tokens: tokens
        )

        #expect(engine.gameState.activePlayerID == result.state.playerOrder[1])
    }

    @Test func verifiedSetupCatalogRejectsInvalidStructureBeforeSetup() throws {
        var catalog = completeCatalog()
        catalog.cards[0].count = 0

        do {
            _ = try makeVerifiedCatalog(catalog)
            Issue.record("Expected invalid catalog rejection")
        } catch GameCore.GameDataLoadError.validationFailed(let issues) {
            #expect(issues.contains { $0.path == "cards" && $0.code == .invalidComponentCount })
        }
    }

    @Test func setupRejectsPlayerCountMasksThatChangeOfficialDeckCardinality() throws {
        var catalog = completeCatalog()
        let cardIndex = try #require(catalog.cards.firstIndex { $0.playerCounts.contains(2) })
        catalog.cards[cardIndex].playerCounts.removeAll { $0 == 2 }
        var rules = GameCore.SetupRules(seed: 2001)

        #expect(throws: GameCore.SetupError.invalidCatalogCardCount(expected: 40, actual: 37)) {
            try rules.makeGame(catalog: makeVerifiedCatalog(catalog), playerIDs: playerIDs(count: 2))
        }
    }

    @Test(arguments: ["tile", "slot"])
    func setupRejectsUnequalMerchantTileAndSlotCardinality(mutation: String) throws {
        var catalog = completeCatalog()
        if mutation == "tile" {
            let index = try #require(catalog.merchants.firstIndex { $0.playerCounts.contains(2) })
            catalog.merchants[index].playerCounts.removeAll { $0 == 2 }
        } else {
            let index = try #require(catalog.board.merchantSlots.firstIndex { $0.playerCounts.contains(2) })
            catalog.board.merchantSlots[index].playerCounts.removeAll { $0 == 2 }
        }
        var rules = GameCore.SetupRules(seed: 2001)

        #expect(throws: GameCore.SetupError.invalidMerchantCardinality(
            expected: 5,
            tiles: mutation == "tile" ? 3 : 5,
            slots: mutation == "slot" ? 4 : 5
        )) {
            try rules.makeGame(catalog: makeVerifiedCatalog(catalog), playerIDs: playerIDs(count: 2))
        }
    }

    @Test func committedDraftManifestCannotProduceASetupCatalogProof() throws {
        let directory = committedDataDirectory()
        let manifestData = try Data(contentsOf: directory.appending(path: "manifest.json"))
        let manifest = try JSONDecoder().decode(GameCore.GameDataManifest.self, from: manifestData)
        let files = try Dictionary(uniqueKeysWithValues: manifest.files.map { entry in
            (entry.path, try Data(contentsOf: directory.appending(path: entry.path)))
        })

        do {
            _ = try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
                manifestData: manifestData,
                files: files
            )
            Issue.record("Expected draft manifest rejection")
        } catch GameCore.GameDataLoadError.validationFailed(let issues) {
            #expect(issues.contains { $0.code == .incompleteCatalog })
            #expect(issues.contains { $0.code == .unverifiedSource })
        }
    }

    @Test func productionBundleLoaderCannotStartFromThePackagedDraftRuleset() {
        do {
            _ = try GameCore.GameDataLoader.loadBundledSetupCatalog()
            Issue.record("Expected the packaged draft ruleset to fail readiness validation")
        } catch GameCore.GameDataLoadError.validationFailed(let issues) {
            #expect(issues.contains { $0.code == .incompleteCatalog && $0.path == "manifest.verificationStatus" })
            #expect(issues.contains { $0.code == .unverifiedSource && $0.path.hasPrefix("manifest.") })
            #expect(issues.contains { $0.code == .missingFile } == false)
            #expect(issues.contains { $0.code == .hashMismatch } == false)
        } catch {
            Issue.record("Expected readiness validation after bundle loading, got \(error)")
        }
    }

    @Test func setupHostArchiveRestoresTheCompleteCanonicalGameState() async throws {
        let setup = try setupResult(playerCount: 2, seed: 2001)
        let hostID = setup.state.playerOrder[0]
        let roomID = GameCore.RoomID(rawValue: "complete-setup-restore")
        let tokens = Dictionary(uniqueKeysWithValues: setup.state.playerOrder.map {
            ($0, GameCore.ReconnectToken(rawValue: "secret-\($0.rawValue)"))
        })
        let engine = try setup.state.makeHostEngine(
            roomID: roomID,
            reconnectTokens: tokens,
            protocolVersion: 1
        )
        let archive = SessionArchive.host(
            protocolVersion: 1,
            rulesetVersion: setup.state.rulesetVersion,
            recipientID: hostID,
            state: engine.state,
            gameState: engine.gameState,
            eventWindows: [:],
            tokenReferences: setup.state.playerOrder.map {
                .init(roomID: roomID, playerID: $0)
            },
            peersNeedingRecovery: [],
            commitSequence: 1
        )
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "complete-game-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(
            directory: directory,
            keyProvider: SetupSnapshotKeyProvider()
        )
        try await store.save(archive)
        let loaded = try await store.load(expected: .init(
            protocolVersion: 1,
            rulesetVersion: setup.state.rulesetVersion,
            roomID: roomID,
            recipientID: hostID,
            role: .host
        ))
        let tokenStore = RoomTokenStore(adapter: SetupSecureItemAdapter())
        for (playerID, token) in tokens {
            try await tokenStore.save(.init(roomID: roomID, playerID: playerID, reconnectToken: token))
        }
        let restored = try await RecoveryCoordinator(tokenStore: tokenStore).restoreFixtureOnlyHost(
            archive: loaded,
            expectedHostID: hostID
        )

        #expect(restored.hasCompleteGameState)
        #expect(try restored.gameState.canonicalHash() == setup.state.canonicalHash())
        let plaintext = try JSONEncoder.canonical.encode(loaded)
        #expect(!plaintext.contains(Data("secret-".utf8)))
    }

    @Test func schemaTwoHostArchiveMigratesAsExplicitlyIncompleteLegacyState() async throws {
        let setup = try setupResult(playerCount: 2, seed: 2001)
        let hostID = setup.state.playerOrder[0]
        let roomID = GameCore.RoomID(rawValue: "legacy-schema-two")
        let tokens = Dictionary(uniqueKeysWithValues: setup.state.playerOrder.map {
            ($0, GameCore.ReconnectToken(rawValue: "legacy-secret-\($0.rawValue)"))
        })
        let engine = try setup.state.makeHostEngine(
            roomID: roomID,
            reconnectTokens: tokens,
            protocolVersion: 1
        )
        let completeArchive = SessionArchive.host(
            protocolVersion: 1,
            rulesetVersion: setup.state.rulesetVersion,
            recipientID: hostID,
            state: engine.state,
            gameState: engine.gameState,
            eventWindows: [:],
            tokenReferences: setup.state.playerOrder.map {
                .init(roomID: roomID, playerID: $0)
            },
            peersNeedingRecovery: [],
            commitSequence: 1
        )
        let legacyArchive = try archiveByRemovingGameState(from: completeArchive)
        var envelope = try SnapshotEnvelope(archive: legacyArchive)
        envelope.schemaVersion = 2
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "legacy-schema-two-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plaintext = try JSONEncoder.canonical.encode(envelope)
        let encrypted = try SnapshotCrypto.seal(
            plaintext,
            keyData: try SetupSnapshotKeyProvider().keyData()
        )
        let store = SnapshotStore(directory: directory, keyProvider: SetupSnapshotKeyProvider())
        try encrypted.write(to: store.committedFileURL)
        let loaded = try await store.load(expected: .init(
            protocolVersion: 1,
            rulesetVersion: setup.state.rulesetVersion,
            roomID: roomID,
            recipientID: hostID,
            role: .host
        ))
        let tokenStore = RoomTokenStore(adapter: SetupSecureItemAdapter())
        for (playerID, token) in tokens {
            try await tokenStore.save(.init(roomID: roomID, playerID: playerID, reconnectToken: token))
        }
        let restored = try await RecoveryCoordinator(tokenStore: tokenStore).restoreFixtureOnlyHost(
            archive: loaded,
            expectedHostID: hostID
        )

        #expect(restored.hasCompleteGameState == false)
        #expect(restored.state == engine.state)
        #expect(try restored.gameState.canonicalHash() != setup.state.canonicalHash())

        let hub = LoopbackTransportHub()
        let coordinator = try SessionCoordinator(
            configuration: .init(
                protocolVersion: 1,
                rulesetVersion: setup.state.rulesetVersion,
                roomID: roomID,
                playerID: hostID,
                reconnectToken: try #require(tokens[hostID]),
                hostPlayerID: hostID
            ),
            restored: restored,
            transport: hub.makeTransport(peerID: hostID),
            persistence: store,
            tokenStore: tokenStore,
            rulesMode: .fixtureOnlyLegacy
        )
        await #expect(throws: SessionCoordinator.Error.persistenceUnavailable) {
            try await coordinator.persistForBackground()
        }
        let loadedAgain = try await store.load(expected: .init(
            protocolVersion: 1,
            rulesetVersion: setup.state.rulesetVersion,
            roomID: roomID,
            recipientID: hostID,
            role: .host
        ))
        let restoredAgain = try await RecoveryCoordinator(tokenStore: tokenStore).restoreFixtureOnlyHost(
            archive: loadedAgain,
            expectedHostID: hostID
        )
        #expect(restoredAgain.hasCompleteGameState == false)
    }

    @Test func schemaThreeHostArchiveRejectsMissingCompleteGameState() async throws {
        let setup = try setupResult(playerCount: 2, seed: 2001)
        let hostID = setup.state.playerOrder[0]
        let roomID = GameCore.RoomID(rawValue: "malformed-schema-three")
        let tokens = Dictionary(uniqueKeysWithValues: setup.state.playerOrder.map {
            ($0, GameCore.ReconnectToken(rawValue: "token-\($0.rawValue)"))
        })
        let engine = try setup.state.makeHostEngine(
            roomID: roomID,
            reconnectTokens: tokens,
            protocolVersion: 1
        )
        let complete = SessionArchive.host(
            protocolVersion: 1,
            rulesetVersion: setup.state.rulesetVersion,
            recipientID: hostID,
            state: engine.state,
            gameState: engine.gameState,
            eventWindows: [:],
            tokenReferences: setup.state.playerOrder.map {
                .init(roomID: roomID, playerID: $0)
            },
            peersNeedingRecovery: [],
            commitSequence: 1
        )
        let malformed = try archiveByRemovingGameState(from: complete)
        var envelope = try SnapshotEnvelope(archive: malformed)
        envelope.schemaVersion = SnapshotEnvelope.currentSchemaVersion
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "malformed-schema-three-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encrypted = try SnapshotCrypto.seal(
            JSONEncoder.canonical.encode(envelope),
            keyData: try SetupSnapshotKeyProvider().keyData()
        )
        let store = SnapshotStore(directory: directory, keyProvider: SetupSnapshotKeyProvider())
        try encrypted.write(to: store.committedFileURL)

        await #expect(throws: SnapshotStoreError.privacyViolation) {
            try await store.load(expected: .init(
                protocolVersion: 1,
                rulesetVersion: setup.state.rulesetVersion,
                roomID: roomID,
                recipientID: hostID,
                role: .host
            ))
        }
    }

    private func verifySetup(
        playerCount: Int,
        seed: UInt64,
        roundCapacity: Int
    ) throws {
        let catalog = completeCatalog()
        let inputPlayers = playerIDs(count: playerCount)
        var firstRules = GameCore.SetupRules(seed: seed)
        var secondRules = GameCore.SetupRules(seed: seed)

        let verifiedCatalog = verifiedCatalog(catalog)
        let first = try firstRules.makeGame(catalog: verifiedCatalog, playerIDs: inputPlayers)
        let second = try secondRules.makeGame(catalog: verifiedCatalog, playerIDs: inputPlayers)
        let state = first.state
        let expectedStandardDeckCount = [2: 40, 3: 54, 4: 64][playerCount]

        #expect(first == second)
        #expect(Set(state.playerOrder) == Set(inputPlayers))
        #expect(state.activePlayerID == state.playerOrder.first)
        #expect(state.players.map(\.id) == state.playerOrder)
        #expect(state.playerCount == playerCount)
        #expect(state.era == .canal)
        #expect(state.roundNumber == 1)
        #expect(state.actionsRemaining == 1)
        #expect(state.actionNumber == 0)
        #expect(state.authoritativeVersion == .init(rawValue: 0))
        #expect(state.players.allSatisfy {
            $0.cash == 17
                && $0.incomePosition == 10
                && $0.victoryPoints == 0
                && $0.spent == 0
                && $0.hand.count == 8
                && $0.privateBottomDiscard != nil
        })
        #expect(Set(state.players.map(\.color)).count == playerCount)
        #expect(state.coalMarket.slots.map(\.price) == [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7])
        #expect(state.coalMarket.slots.filter(\.hasCube).count == 13)
        #expect(state.coalMarket.slots.filter { $0.price == 1 && $0.hasCube == false }.count == 1)
        #expect(state.ironMarket.slots.map(\.price) == [1, 1, 1, 2, 2, 2, 3, 3, 4, 4])
        #expect(state.ironMarket.slots.filter(\.hasCube).count == 8)
        #expect(state.ironMarket.slots.filter { $0.price == 1 && $0.hasCube == false }.count == 2)
        #expect(state.canalRoundCapacity == roundCapacity)
        #expect(state.railRoundCapacity == roundCapacity)
        #expect(state.publicDiscard.isEmpty)
        #expect(state.boardIndustryPlacements.isEmpty)
        #expect(state.placedLinks.isEmpty)

        let allCards = state.players.flatMap(\.hand)
            + state.players.compactMap(\.privateBottomDiscard)
            + state.standardDrawDeck
        #expect(allCards.count == expectedStandardDeckCount)
        let cardDefinitions = Dictionary(uniqueKeysWithValues: catalog.cards.map { ($0.id, $0) })
        #expect(allCards.count == catalog.cards
            .filter { $0.playerCounts.contains(playerCount) && $0.kind != .wildLocation && $0.kind != .wildIndustry }
            .reduce(0) { $0 + $1.count })
        #expect(allCards.allSatisfy {
            cardDefinitions[$0.definitionID]?.playerCounts.contains(playerCount) == true
        })
        #expect(allCards.allSatisfy {
            cardDefinitions[$0.definitionID]?.kind != .wildLocation
                && cardDefinitions[$0.definitionID]?.kind != .wildIndustry
        })
        #expect(state.wildLocationPool.count == 4)
        #expect(state.wildIndustryPool.count == 4)

        let expectedIndustryLevels = Dictionary(uniqueKeysWithValues: catalog.industries.map { definition in
            (
                definition.id,
                definition.levels.sorted { $0.level < $1.level }.flatMap { level in
                    Array(repeating: level.level, count: level.copiesPerColor)
                }
            )
        })
        #expect(state.players.allSatisfy { player in
            Dictionary(uniqueKeysWithValues: player.industryStacks.map {
                ($0.industryDefinitionID, $0.tiles.map(\.level))
            }) == expectedIndustryLevels
        })

        let expectedSlots = catalog.board.merchantSlots.filter { $0.playerCounts.contains(playerCount) }
        let merchantDefinitions = Dictionary(uniqueKeysWithValues: catalog.merchants.map { ($0.id, $0) })
        #expect(state.merchants.count == expectedSlots.count)
        #expect(Set(state.merchants.map(\.slotID)) == Set(expectedSlots.map(\.id)))
        #expect(state.merchants.allSatisfy {
            merchantDefinitions[$0.merchantDefinitionID]?.playerCounts.contains(playerCount) == true
        })
        #expect(state.merchants.allSatisfy {
            $0.hasBeer == ($0.merchantDefinitionID.hasPrefix("blank-") == false)
        })
        let merchantBeer = state.merchants.filter(\.hasBeer).count
        #expect(state.publicSupply == .init(
            coal: 17,
            iron: 10,
            beer: 15 - merchantBeer,
            mayUseSubstitutes: true
        ))

        #expect(try GameCore.SetupRules.replay(first.events, catalog: verifiedCatalog) == state)
        #expect(try state.canonicalBytes() == second.state.canonicalBytes())
        #expect(try state.canonicalHash() == second.state.canonicalHash())
    }

    private func playerIDs(count: Int) -> [GameCore.PlayerID] {
        (1...count).map { .init(rawValue: "player-\($0)") }
    }

    private func setupResult(playerCount: Int, seed: UInt64) throws -> GameCore.SetupResult {
        var rules = GameCore.SetupRules(seed: seed)
        return try rules.makeGame(
            catalog: verifiedCatalog(completeCatalog()),
            playerIDs: playerIDs(count: playerCount)
        )
    }

    private func submitPass(
        to engine: inout GameCore.HostEngine,
        playerID: GameCore.PlayerID,
        roomID: GameCore.RoomID,
        tokens: [GameCore.PlayerID: GameCore.ReconnectToken]
    ) throws {
        let player = try #require(engine.gameState.players.first { $0.id == playerID })
        let card = try #require(player.hand.first)
        let result = engine.submit(.init(
            protocolVersion: engine.protocolVersion,
            rulesetVersion: engine.rulesetVersion,
            roomID: roomID,
            senderID: playerID,
            reconnectToken: try #require(tokens[playerID]),
            baseVersion: engine.gameState.authoritativeVersion,
            payload: .pass(.init(cardID: card.id))
        ), catalog: verifiedCatalog(completeCatalog()))
        guard case .accepted = result else {
            Issue.record("Expected pass by \(playerID.rawValue) to be accepted")
            return
        }
    }

    private func resequenced(_ events: [GameCore.SetupEvent]) -> [GameCore.SetupEvent] {
        events.enumerated().map { GameCore.SetupEvent(sequence: $0.offset, payload: $0.element.payload) }
    }

    private func replayError(
        _ events: [GameCore.SetupEvent],
        catalog: GameCore.VerifiedGameDataCatalog? = nil
    ) -> GameCore.SetupReplayError? {
        do {
            _ = try GameCore.SetupRules.replay(
                events,
                catalog: catalog ?? verifiedCatalog(completeCatalog())
            )
            return nil
        } catch GameCore.SetupError.invalidReplay(let code) {
            return code
        } catch {
            return nil
        }
    }

    private func completeCatalog() -> GameCore.GameDataCatalog {
        let directory = committedDataDirectory()
        return try! GameCore.GameDataLoader.decodeCatalog(
            rulesetVersion: "v2018.11",
            mapData: Data(contentsOf: directory.appending(path: "map.json")),
            industryData: Data(contentsOf: directory.appending(path: "industries.json")),
            cardData: Data(contentsOf: directory.appending(path: "cards.json")),
            merchantData: Data(contentsOf: directory.appending(path: "merchants.json")),
            incomeTrackData: Data(contentsOf: directory.appending(path: "income-track.json"))
        )
    }

    private func verifiedCatalog(
        _ catalog: GameCore.GameDataCatalog
    ) -> GameCore.VerifiedGameDataCatalog {
        try! makeVerifiedCatalog(catalog)
    }

    private func makeVerifiedCatalog(
        _ catalog: GameCore.GameDataCatalog
    ) throws -> GameCore.VerifiedGameDataCatalog {
        let encoder = JSONEncoder()
        let files = try [
            "map.json": encoder.encode(catalog.board),
            "industries.json": encoder.encode(catalog.industries),
            "cards.json": encoder.encode(catalog.cards),
            "merchants.json": encoder.encode(catalog.merchants),
            "income-track.json": encoder.encode(catalog.incomeTrack),
        ]
        let manifestFiles = try files.keys.sorted().map { path in
            let data = try #require(files[path])
            return GameCore.GameDataManifest.FileDigest(
                path: path,
                sha256: GameCore.GameDataLoader.sha256(data)
            )
        }
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: catalog.rulesetVersion,
            verificationStatus: .verified,
            files: manifestFiles,
            sources: [
                .init(
                    id: "setup-test-proof",
                    url: "https://example.com/setup-test-proof",
                    component: "test-only complete setup catalog",
                    version: catalog.rulesetVersion,
                    page: "test fixture",
                    transcriber: "setup test transcriber",
                    transcribedOn: "2026-08-17",
                    checker: "setup test checker",
                    checkedOn: "2026-08-17"
                ),
            ]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest),
            files: files
        )
    }

    private func committedDataDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "IndustrialCityBirmingham/GameData/v2018.11")
    }

    private func archiveByRemovingGameState(from archive: SessionArchive) throws -> SessionArchive {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder.canonical.encode(archive))
        func removingGameState(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.reduce(into: [String: Any]()) { result, entry in
                    if entry.key != "gameState" {
                        result[entry.key] = removingGameState(entry.value)
                    }
                }
            }
            if let array = value as? [Any] { return array.map(removingGameState) }
            return value
        }
        return try JSONDecoder().decode(
            SessionArchive.self,
            from: JSONSerialization.data(withJSONObject: removingGameState(object), options: [.sortedKeys])
        )
    }
}

private struct SetupSnapshotKeyProvider: SnapshotKeyProvider {
    func keyData() throws -> Data { Data(repeating: 0x5A, count: 32) }
}

private final class SetupSecureItemAdapter: SecureItemAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(service: String, account: String) throws -> Data? {
        lock.withLock { values["\(service):\(account)"] }
    }

    func readAll(service: String) throws -> [Data] {
        lock.withLock {
            values.compactMap { key, value in key.hasPrefix("\(service):") ? value : nil }
        }
    }

    func add(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            let key = "\(service):\(account)"
            guard values[key] == nil else { throw SecureItemAdapterError.duplicateItem }
            values[key] = data
        }
    }

    func update(_ data: Data, service: String, account: String) throws {
        lock.withLock { values["\(service):\(account)"] = data }
    }

    func delete(service: String, account: String) throws {
        lock.withLock { values["\(service):\(account)"] = nil }
    }
}
