import Foundation
import Testing

@testable import IndustrialCityBirmingham

struct GameRulesEngineTests {
    struct CompleteGameProof {
        let finalState: GameCore.GameState
        let finalHash: String
        let ordinaryIntentCount: Int
        let events: [GameCore.AuthoritativeGameEvent]
    }

    @Test(arguments: [2, 3, 4])
    func seededCompleteGamesProduceReplayableDeterministicProofs(playerCount: Int) throws {
        let first = try runCompleteGame(playerCount: playerCount)
        let second = try runCompleteGame(playerCount: playerCount)

        #expect(first.finalState.turnPhase == .ended)
        #expect(first.finalState.era == .rail)
        #expect(first.finalHash == second.finalHash)
        let expectedHashes = [
            2: "da4e0e405139b24c500f9820bb496025bea0f35f6fd306a8176d5d04beae556f",
            3: "6209a2452e4fa6f71aa53d3c1d368864a06fba2c70c78f4fdd6c7aaa31e119fd",
            4: "5d1144952cdd74fa58f7fa37f87e979e52de3dac3e189bc3d0bcd03e2d4df129",
        ]
        #expect(first.finalHash == expectedHashes[playerCount])
        #expect(first.events == second.events)
        #expect(first.finalState == second.finalState)
        #expect(first.finalState.authoritativeVersion.rawValue == first.events.count)
        #expect(first.finalState.authoritativeVersion.rawValue == first.ordinaryIntentCount)
        #expect(first.finalState.actionNumber == first.ordinaryIntentCount)
        #expect(first.events.allSatisfy {
            if case .forcedSaleResolved = $0.payload { return false }
            return true
        })
        #expect(first.events.last?.transitions.contains {
            if case .gameEnded = $0 { return true }
            return false
        } == true)

        print("TASK10_FINAL_HASH players=\(playerCount) hash=\(first.finalHash)")
    }

    @Test func forcedSaleSubmittedThroughHostIncrementsVersionAndReplaysExactly() throws {
        let catalog = try verifiedCatalog()
        var setupRules = GameCore.SetupRules(seed: 10_099)
        var state = try setupRules.makeGame(
            catalog: catalog, playerIDs: [.init(rawValue: "debtor"), .init(rawValue: "other")]
        ).state
        let debtor = state.playerOrder[0]
        let debtorIndex = try #require(state.players.firstIndex { $0.id == debtor })
        let canonicalTiles = state.players[debtorIndex].industryStacks.flatMap(\.tiles)
        let stackIndex = try #require(state.players[debtorIndex].industryStacks.firstIndex {
            $0.industryDefinitionID == "manufacturer"
        })
        let canonicalTile = try #require(
            state.players[debtorIndex].industryStacks[stackIndex].tiles.first
        )
        state.players[debtorIndex].industryStacks[stackIndex].tiles.removeFirst()
        state.players[debtorIndex].cash = 0
        state.players[debtorIndex].incomePosition = 0
        let location = try #require(catalog.catalog.board.locations.first { location in
            location.industrySlots.contains { $0.contains("manufacturer") }
        })
        let slotIndex = try #require(location.industrySlots.firstIndex { $0.contains("manufacturer") })
        state.boardIndustryPlacements = [.init(
            placementID: "forced-sale-proof", locationID: location.id, slotIndex: slotIndex,
            ownerID: debtor,
            tile: canonicalTile
        )]
        let proofTile = try #require(state.boardIndustryPlacements.first?.tile)
        #expect(canonicalTiles.contains(proofTile))
        #expect(state.players[debtorIndex].industryStacks.flatMap(\.tiles).contains(proofTile) == false)
        _ = try GameCore.GameRulesEngine.resolveRoundEnd(state: &state, catalog: catalog)
        guard case .forcedSale(let pending) = state.turnPhase else {
            Issue.record("round income must create a real pending forced sale")
            return
        }

        let pendingState = state
        #expect(GameCore.GameStateAuthorityValidator.isValid(pendingState, catalog: catalog))
        let roomID = GameCore.RoomID(rawValue: "forced-sale-proof-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "proof-token-\($0.id.rawValue)"))
        })
        var engine = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
        )
        let result = engine.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion,
            roomID: roomID, senderID: debtor,
            reconnectToken: try #require(tokens[debtor]),
            baseVersion: state.authoritativeVersion,
            payload: .forcedSale(.init(placementIDs: pending.eligiblePlacementIDs))
        ), catalog: catalog)
        guard case .accepted(let event) = result else {
            Issue.record("HostEngine must accept the typed forced-sale intent: \(result)")
            return
        }

        #expect(event.previousVersion == pendingState.authoritativeVersion)
        #expect(event.version.rawValue == event.previousVersion.rawValue + 1)
        #expect(event.actionNumber == pendingState.actionNumber + 1)
        #expect(engine.gameState.authoritativeVersion == event.version)
        #expect(engine.gameState.actionNumber == event.actionNumber)
        guard case .forcedSaleResolved(let resolved) = event.payload else {
            Issue.record("HostEngine must emit a forced-sale authoritative event")
            return
        }
        #expect(resolved.placementIDs == pending.eligiblePlacementIDs)

        var replayed = pendingState
        try GameCore.GameRulesEngine.replay(
            event, expectedRoomID: roomID, to: &replayed, catalog: catalog
        )
        #expect(replayed == engine.gameState)
    }

    private func runCompleteGame(playerCount: Int) throws -> CompleteGameProof {
        let catalog = try verifiedCatalog()
        let seed = UInt64(10_000 + playerCount)
        let players = (1...playerCount).map { GameCore.PlayerID(rawValue: "proof-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: seed)
        let initialState = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let roomID = GameCore.RoomID(rawValue: "proof-room-\(playerCount)")
        let tokens = Dictionary(uniqueKeysWithValues: players.map {
            ($0, GameCore.ReconnectToken(rawValue: "proof-token-\($0.rawValue)"))
        })
        var engine = try initialState.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
        )
        var events: [GameCore.AuthoritativeGameEvent] = []
        var ordinaryIntentCount = 0

        while engine.gameState.turnPhase != .ended {
            guard events.count < 1_000 else {
                Issue.record("complete game exceeded the deterministic safety bound")
                break
            }
            let state = engine.gameState
            guard state.turnPhase == .active else {
                Issue.record("pass-only proof unexpectedly entered forced sale")
                break
            }
            let actor = try #require(state.activePlayerID)
            let card = try #require(state.players.first { $0.id == actor }?.hand.first)
            let payload = GameCore.PlayerIntent.Payload.pass(.init(cardID: card.id))
            ordinaryIntentCount += 1
            let result = engine.submit(.init(
                protocolVersion: 1,
                rulesetVersion: state.rulesetVersion,
                roomID: roomID,
                senderID: actor,
                reconnectToken: try #require(tokens[actor]),
                baseVersion: state.authoritativeVersion,
                payload: payload
            ), catalog: catalog)
            guard case .accepted(let event) = result else {
                Issue.record("legal seeded proof intent was not accepted: \(result)")
                break
            }
            events.append(event)
        }

        var replayed = initialState
        for event in events {
            try GameCore.GameRulesEngine.replay(
                event, expectedRoomID: roomID, to: &replayed, catalog: catalog
            )
        }
        #expect(replayed == engine.gameState)

        return try CompleteGameProof(
            finalState: engine.gameState,
            finalHash: engine.gameState.canonicalHash(),
            ordinaryIntentCount: ordinaryIntentCount,
            events: events
        )
    }

    private func verifiedCatalog() throws -> GameCore.VerifiedGameDataCatalog {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "IndustrialCityBirmingham/GameData/v2018.11")
        let catalog = try GameCore.GameDataLoader.decodeCatalog(
            rulesetVersion: "v2018.11",
            mapData: Data(contentsOf: directory.appending(path: "map.json")),
            industryData: Data(contentsOf: directory.appending(path: "industries.json")),
            cardData: Data(contentsOf: directory.appending(path: "cards.json")),
            merchantData: Data(contentsOf: directory.appending(path: "merchants.json")),
            incomeTrackData: Data(contentsOf: directory.appending(path: "income-track.json"))
        )
        let encoder = JSONEncoder()
        let files = try [
            "map.json": encoder.encode(catalog.board),
            "industries.json": encoder.encode(catalog.industries),
            "cards.json": encoder.encode(catalog.cards),
            "merchants.json": encoder.encode(catalog.merchants),
            "income-track.json": encoder.encode(catalog.incomeTrack),
        ]
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: catalog.rulesetVersion, verificationStatus: .verified,
            files: try files.keys.sorted().map { path in
                .init(path: path, sha256: GameCore.GameDataLoader.sha256(try #require(files[path])))
            },
            sources: [.init(
                id: "complete-game-proof", url: "https://example.com/complete-game-proof",
                component: "test catalog", version: catalog.rulesetVersion, page: "fixture",
                transcriber: "proof-author", transcribedOn: "2026-08-20",
                checker: "proof-reviewer", checkedOn: "2026-08-20"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }
}
