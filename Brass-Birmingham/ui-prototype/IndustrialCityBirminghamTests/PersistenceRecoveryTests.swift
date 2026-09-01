import Foundation
import CryptoKit
import SwiftUI
import Testing
@testable import IndustrialCityBirmingham

@Suite("Persistence and recovery")
struct PersistenceRecoveryTests {
    private let room = GameCore.RoomID(rawValue: "CABIN-42")
    private let player = GameCore.PlayerID(rawValue: "guest-a")

    @Test func roomTokenStoreAddsThenUpdatesTheSameInstalledSeatCredential() async throws {
        let adapter = InMemorySecureItemAdapter()
        let store = RoomTokenStore(adapter: adapter)
        let first = RoomTokenCredential(
            roomID: room,
            playerID: player,
            reconnectToken: .init(rawValue: "token-v1")
        )
        let updated = RoomTokenCredential(
            roomID: room,
            playerID: player,
            reconnectToken: .init(rawValue: "token-v2")
        )

        try await store.save(first)
        try await store.save(updated)

        #expect(try await store.load(roomID: room, playerID: player) == updated)
        #expect(adapter.addCount == 1)
        #expect(adapter.updateCount == 1)
    }

    @Test func roomTokenStoreScopesMissingDeleteAndLookupToExactRoomAndPlayer() async throws {
        let adapter = InMemorySecureItemAdapter()
        let store = RoomTokenStore(adapter: adapter)
        let credential = RoomTokenCredential(
            roomID: room,
            playerID: player,
            reconnectToken: .init(rawValue: "private-token")
        )
        try await store.save(credential)

        #expect(try await store.load(roomID: .init(rawValue: "OTHER"), playerID: player) == nil)
        #expect(try await store.load(roomID: room, playerID: .init(rawValue: "other-player")) == nil)
        try await store.delete(roomID: room, playerID: player)
        #expect(try await store.load(roomID: room, playerID: player) == nil)
        try await store.delete(roomID: room, playerID: player)
    }

    @Test func roomTokenNeverAppearsInItsKeychainLookupMetadata() async throws {
        let adapter = InMemorySecureItemAdapter()
        let store = RoomTokenStore(adapter: adapter)
        let token = "secret-that-must-not-be-indexed"
        try await store.save(.init(
            roomID: room,
            playerID: player,
            reconnectToken: .init(rawValue: token)
        ))

        #expect(adapter.lookupMetadata.allSatisfy { !$0.contains(token) })
        #expect(adapter.allStoredData.count == 1)
    }

    @Test func recoverableHostRoomListingIsHostOnlyDeduplicatedSortedAndDoesNotExposeTokens() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = InMemorySecureItemAdapter()
        let tokenStore = RoomTokenStore(adapter: adapter)
        let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x19, count: 32))
        let factory = SessionPersistenceFactory(baseDirectory: directory, tokenStore: tokenStore, keyProvider: key)
        let hostID = GameCore.PlayerID(rawValue: "host")
        for roomName in ["ROOM-Z", "ROOM-A"] {
            let roomID = GameCore.RoomID(rawValue: roomName)
            try await tokenStore.save(.init(
                roomID: roomID, playerID: hostID,
                reconnectToken: .init(rawValue: "secret-\(roomName)")
            ))
            try await tokenStore.save(.init(
                roomID: roomID, playerID: player,
                reconnectToken: .init(rawValue: "guest-secret-\(roomName)")
            ))
            let archive = try await makeHostArchive(roomID: roomID, hostID: hostID)
            try await SnapshotStore(
                directory: factory.directory(roomID: roomID, playerID: hostID), keyProvider: key
            ).save(archive)
        }
        try await tokenStore.save(.init(
            roomID: .init(rawValue: "GUEST-ONLY"), playerID: player,
            reconnectToken: .init(rawValue: "guest-secret")
        ))

        let references = try await factory.recoverableFixtureOnlyHostRooms()

        #expect(references.map(\.roomID.rawValue) == ["ROOM-A", "ROOM-Z"])
        #expect(references.allSatisfy { $0.playerID == hostID && $0.role == .host })
        let encoded = try JSONEncoder.canonical.encode(references)
        #expect(!encoded.contains(Data("secret".utf8)))
        #expect(!encoded.contains(Data("guest-secret".utf8)))
    }

    @Test func recoverableHostRoomListingRequiresDecryptableDeeplyRestorableHostMaterial() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
        let keyData = Data(repeating: 0x1A, count: 32)
        let key = FixedSnapshotKeyProvider(key: keyData)
        let factory = SessionPersistenceFactory(baseDirectory: directory, tokenStore: tokenStore, keyProvider: key)
        let hostID = GameCore.PlayerID(rawValue: "host")
        let cases = ["VALID", "TAMPER", "TRUNCATED", "WRONG-KEY", "GUEST-ROLE"]
        for roomName in cases {
            let roomID = GameCore.RoomID(rawValue: roomName)
            try await tokenStore.save(.init(
                roomID: roomID, playerID: hostID, reconnectToken: .init(rawValue: "host-(roomName)")
            ))
            try await tokenStore.save(.init(
                roomID: roomID, playerID: player, reconnectToken: .init(rawValue: "guest-(roomName)")
            ))
            let store = SnapshotStore(
                directory: factory.directory(roomID: roomID, playerID: hostID), keyProvider: key
            )
            if roomName == "GUEST-ROLE" {
                let guest = SessionArchive.guest(
                    protocolVersion: 1, rulesetVersion: "rules-v1",
                    hostPlayerID: hostID,
                    snapshot: makeSnapshot(recipient: hostID, opponentHand: nil, version: 0),
                    eventWindow: [], tokenReference: .init(roomID: roomID, playerID: hostID),
                    commitSequence: 1
                )
                try writeUnchecked(guest, key: keyData, to: store.committedFileURL)
            } else {
                let archive = try await makeHostArchive(roomID: roomID, hostID: hostID)
                let saveKey = roomName == "WRONG-KEY" ? Data(repeating: 0x1B, count: 32) : keyData
                try writeUnchecked(archive, key: saveKey, to: store.committedFileURL)
                if roomName == "TAMPER" {
                    var bytes = try Data(contentsOf: store.committedFileURL)
                    bytes[bytes.index(before: bytes.endIndex)] ^= 1
                    try bytes.write(to: store.committedFileURL)
                } else if roomName == "TRUNCATED" {
                    try Data((try Data(contentsOf: store.committedFileURL)).prefix(8)).write(to: store.committedFileURL)
                }
            }
        }

        let rooms = try await factory.recoverableFixtureOnlyHostRooms()
        #expect(rooms.map(\.roomID.rawValue) == ["VALID"])
    }

    @Test func invalidRecoverableHostListingUsesSharedThreeFailurePolicyAndKeepsKeychainToken() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
        let keyData = Data(repeating: 0x1C, count: 32)
        let factory = SessionPersistenceFactory(
            baseDirectory: directory, tokenStore: tokenStore,
            keyProvider: FixedSnapshotKeyProvider(key: keyData)
        )
        let hostID = GameCore.PlayerID(rawValue: "host")
        let roomID = GameCore.RoomID(rawValue: "INVALID-LISTING")
        let credential = RoomTokenCredential(
            roomID: roomID, playerID: hostID, reconnectToken: .init(rawValue: "keep-token")
        )
        try await tokenStore.save(credential)
        let store = SnapshotStore(
            directory: factory.directory(roomID: roomID, playerID: hostID),
            keyProvider: FixedSnapshotKeyProvider(key: keyData)
        )
        let state = GameCore.AuthoritativeGameState(
            roomID: roomID,
            players: [.init(id: hostID, reconnectToken: credential.reconnectToken, hand: ["host-card"])],
            activePlayerID: hostID, turn: 1, actionNumber: 0,
            authoritativeVersion: .init(rawValue: 0), discardPile: []
        )
        try await store.save(SessionArchive.host(
            protocolVersion: 1, rulesetVersion: "rules-v1", recipientID: hostID,
            state: state,
            gameState: .legacyCompatible(state, rulesetVersion: "rules-v1"),
            eventWindows: [:],
            tokenReferences: [.init(roomID: roomID, playerID: hostID)],
            peersNeedingRecovery: [], commitSequence: 1
        ))
        var bytes = try Data(contentsOf: store.committedFileURL)
        bytes[bytes.index(before: bytes.endIndex)] ^= 1
        try bytes.write(to: store.committedFileURL)

        #expect(try await factory.recoverableFixtureOnlyHostRooms().isEmpty)
        #expect(try await factory.recoverableFixtureOnlyHostRooms().isEmpty)
        await #expect(throws: RecoveryError.returnToLobby("recovery-material-invalid")) {
            _ = try await factory.recoverableFixtureOnlyHostRooms()
        }
        #expect(!FileManager.default.fileExists(atPath: store.committedFileURL.path))
        #expect(try await tokenStore.load(roomID: roomID, playerID: hostID) == credential)
    }

    @MainActor
    @Test func nearbyRecoveryRouteBuildsHostStoreForTheSelectedPersistedRoom() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = InMemorySecureItemAdapter()
        let tokenStore = RoomTokenStore(adapter: adapter)
        let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x20, count: 32))
        let factory = SessionPersistenceFactory(baseDirectory: directory, tokenStore: tokenStore, keyProvider: key)
        let catalog = try verifiedCatalog()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let roomID = GameCore.RoomID(rawValue: "ROOM-RESTORE")
        let archive = try await makeCompleteHostArchive(
            roomID: roomID, hostID: hostID, catalog: catalog, tokenStore: tokenStore
        )
        try await SnapshotStore(
            directory: factory.directory(roomID: roomID, playerID: hostID), keyProvider: key,
            verifiedCatalog: catalog
        ).save(archive)
        let reference = try #require(try await factory.recoverableHostRooms(catalog: catalog).first)

        let store = try await NearbyHostRecoveryRoute.makeStore(
            reference: reference,
            identity: .init(deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
            persistenceFactory: factory,
            transport: LoopbackTransportHub().makeTransport(peerID: hostID),
            catalog: catalog
        )

        #expect(store.roomID == roomID)
        #expect(store.isHost)
    }

    @MainActor
    @Test func verifiedRulesetHostArchiveListsRestoresAndAcceptsTheNextBuild() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
        let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x22, count: 32))
        let factory = SessionPersistenceFactory(
            baseDirectory: directory, tokenStore: tokenStore, keyProvider: key
        )
        let catalog = try verifiedCatalog()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let roomID = GameCore.RoomID(rawValue: "V2018-RESTORE")
        let archive = try await makeCompleteHostArchive(
            roomID: roomID, hostID: hostID, catalog: catalog, tokenStore: tokenStore
        )
        try await SnapshotStore(
            directory: factory.directory(roomID: roomID, playerID: hostID), keyProvider: key
        ).save(archive)

        let reference = try #require(try await factory.recoverableHostRooms(catalog: catalog).first)
        #expect(reference.rulesetVersion == "v2018.11")
        let store = try await NearbyHostRecoveryRoute.makeStore(
            reference: reference,
            identity: .init(deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
            persistenceFactory: factory,
            transport: LoopbackTransportHub().makeTransport(peerID: hostID),
            catalog: catalog
        )
        #expect(await store.connect() == nil)
        try await eventuallyMainActor { store.snapshot != nil }

        guard case let .host(hostArchive) = archive.payload else {
            Issue.record("Expected host archive")
            return
        }
        let gameState = try #require(hostArchive.gameState)
        let actor = try #require(gameState.activePlayerID)
        #expect(actor == hostID)
        let playerState = try #require(gameState.players.first(where: { $0.id == actor }))
        let builds = playerState.industryStacks.compactMap { stack -> (String, GameCore.IndustryTile, GameCore.IndustryDefinition.Level)? in
            guard let tile = stack.tiles.first,
                  let level = catalog.catalog.industries.first(where: { $0.id == stack.industryDefinitionID })?
                    .levels.first(where: { $0.level == tile.level }),
                  level.coalCost + level.ironCost + level.beerCost <= 1
            else { return nil }
            return (stack.industryDefinitionID, tile, level)
        }.compactMap { industryID, tile, level in
            playerState.hand.compactMap { card in
                GameCore.BuildRules.legalBuildTargets(
                    actorID: actor, cardID: card.id, tile: tile,
                    state: gameState, catalog: catalog
                ).first.map { (card, industryID, level, $0) }
            }.first
        }
        let build = try #require(builds.first)
        let resources = try resourceSources(
            level: build.2, locationID: build.3.locationID, state: gameState, catalog: catalog
        )
        let payload = GameCore.PlayerIntent.Payload.build(.init(
            cardID: build.0.id, locationID: build.3.locationID,
            industryDefinitionID: build.1, slotIndex: build.3.slotIndex,
            resourceSources: resources
        ))
        try await store.submitForTesting(payload)
        try await eventuallyMainActor { store.version.rawValue == 1 }
        #expect(store.syncStatus == .recovering)
        #expect(store.errorMessage == "当前行动玩家已断线，正在等待其恢复连接。")
    }

    @Test func protocolV2NearbyFlowPersistsInitialAndActionSnapshotsWithRealStore() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
        let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x79, count: 32))
        let factory = SessionPersistenceFactory(
            baseDirectory: directory,
            tokenStore: tokenStore,
            keyProvider: key
        )
        let catalog = try verifiedCatalog()
        let roomID = GameCore.RoomID(rawValue: "REAL-V2-SAVE")
        let hostID = GameCore.PlayerID(rawValue: "host")
        let guestID = GameCore.PlayerID(rawValue: "guest-a")
        let hub = LoopbackTransportHub()
        let host = try await factory.makeCoordinator(
            configuration: .init(
                protocolVersion: 2,
                rulesetVersion: catalog.catalog.rulesetVersion,
                roomID: roomID,
                playerID: hostID,
                reconnectToken: .init(rawValue: "host-token"),
                hostPlayerID: hostID
            ),
            role: .host,
            transport: hub.makeTransport(peerID: hostID),
            rulesMode: .verified(catalog)
        )
        let guest = try await factory.makeCoordinator(
            configuration: .init(
                protocolVersion: 2,
                rulesetVersion: catalog.catalog.rulesetVersion,
                roomID: roomID,
                playerID: guestID,
                reconnectToken: .init(rawValue: "guest-token"),
                hostPlayerID: hostID
            ),
            role: .guest,
            transport: hub.makeTransport(peerID: guestID),
            rulesMode: .verified(catalog)
        )

        try await host.createRoom()
        try await guest.joinRoom()
        try await host.setReady(true)
        try await guest.setReady(true)
        try await eventually { await host.readyPlayerIDs.count == 2 }
        try await host.startGame()
        try await eventually { await guest.snapshot != nil }

        let guestStore = SnapshotStore(
            directory: factory.directory(roomID: roomID, playerID: guestID),
            keyProvider: key,
            verifiedCatalog: catalog
        )
        try await eventually {
            let saveFailed = await guest.persistenceError != nil
            return FileManager.default.fileExists(atPath: guestStore.committedFileURL.path) || saveFailed
        }
        #expect(await guest.persistenceError == nil)
        #expect(FileManager.default.fileExists(atPath: guestStore.committedFileURL.path))

        let actorID = try #require(await host.snapshot?.activePlayerID)
        let actingCoordinator = actorID == hostID ? host : guest
        let actorSnapshot = try #require(await actingCoordinator.snapshot)
        let cardID = try #require(actorSnapshot.players.first(where: { $0.id == actorID })?.hand?.first)
        try await actingCoordinator.pass(discardCardID: cardID)
        try await eventually { await host.snapshot?.authoritativeVersion == .init(rawValue: 1) }

        #expect(await host.persistenceError == nil)
        #expect(await guest.persistenceError == nil)
        let hostStore = SnapshotStore(
            directory: factory.directory(roomID: roomID, playerID: hostID),
            keyProvider: key,
            verifiedCatalog: catalog
        )
        #expect(FileManager.default.fileExists(atPath: hostStore.committedFileURL.path))
        #expect(try await hostStore.load(expected: .init(
            protocolVersion: 2,
            rulesetVersion: catalog.catalog.rulesetVersion,
            roomID: roomID,
            recipientID: hostID,
            role: .host
        )).authoritativeVersion == .init(rawValue: 1))
    }

    @Test func railPreparedHandCountsKeepHostSnapshotChecksumStableAfterDecoding() throws {
        let fixture = makeRailPreparedChecksumArchive()
        let playerIDs = fixture.playerIDs
        let railDetails = fixture.railDetails
        let detailsObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder.canonical.encode(railDetails)) as? [String: Any]
        )
        let encodedHandCounts = try #require(detailsObject["handCounts"] as? [Any])
        let encodedPlayerIDs = try stride(from: 0, to: encodedHandCounts.count, by: 2).map { index in
            try #require(encodedHandCounts[index] as? String)
        }
        #expect(encodedPlayerIDs == playerIDs.map(\.rawValue).sorted())
        let storedEnvelope = try SnapshotEnvelope(archive: fixture.archive)

        let decodedEnvelope = try JSONDecoder().decode(
            SnapshotEnvelope.self,
            from: JSONEncoder.canonical.encode(storedEnvelope)
        )

        #expect(decodedEnvelope.checksum == (try SnapshotEnvelope.checksum(for: decodedEnvelope.archive)))
    }

    @Test func legacySchema4ArchiveLoadsAndMigratesToStableCurrentSchema() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 0x7A, count: 32)
        let fixture = makeRailPreparedChecksumArchive()
        let legacy = try makeLegacySchema4EnvelopeData(archive: fixture.archive)
        #expect(legacy.checksum != (try SnapshotEnvelope.checksum(for: fixture.archive)))

        let store = SnapshotStore(
            directory: directory,
            keyProvider: FixedSnapshotKeyProvider(key: key)
        )
        try FileManager.default.createDirectory(
            at: store.committedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try SnapshotCrypto.seal(legacy.data, keyData: key).write(to: store.committedFileURL)

        let loaded = try await store.load(expected: .init(
            protocolVersion: 1,
            rulesetVersion: "rules-v1",
            roomID: fixture.archive.roomID,
            recipientID: GameCore.PlayerID(rawValue: "host"),
            role: .host
        ))
        #expect(loaded == fixture.archive)

        let migratedData = try SnapshotCrypto.open(
            Data(contentsOf: store.committedFileURL),
            keyData: key
        )
        let migrated = try JSONDecoder().decode(SnapshotEnvelope.self, from: migratedData)
        #expect(migrated.schemaVersion == SnapshotEnvelope.currentSchemaVersion)
        #expect(migrated.schemaVersion == 5)
        #expect(migrated.checksum == (try SnapshotEnvelope.checksum(for: migrated.archive)))
    }

    @Test func legacySchema4ArchiveAllowsTheNextSaveAndReplacesItWithSchema5() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 0x7B, count: 32)
        let fixture = makeRailPreparedChecksumArchive()
        let legacy = try makeLegacySchema4EnvelopeData(archive: fixture.archive)
        let store = SnapshotStore(
            directory: directory,
            keyProvider: FixedSnapshotKeyProvider(key: key)
        )
        try SnapshotCrypto.seal(legacy.data, keyData: key).write(to: store.committedFileURL)
        let next = SessionArchive(
            protocolVersion: fixture.archive.protocolVersion,
            rulesetVersion: fixture.archive.rulesetVersion,
            roomID: fixture.archive.roomID,
            recipientID: fixture.archive.recipientID,
            role: fixture.archive.role,
            authoritativeVersion: fixture.archive.authoritativeVersion,
            commitSequence: fixture.archive.commitSequence + 1,
            payload: fixture.archive.payload,
            gameVariant: fixture.archive.gameVariant
        )

        try await store.save(next)

        let savedData = try SnapshotCrypto.open(
            Data(contentsOf: store.committedFileURL),
            keyData: key
        )
        let saved = try JSONDecoder().decode(SnapshotEnvelope.self, from: savedData)
        #expect(saved.schemaVersion == 5)
        #expect(saved.archive == next)
        #expect(saved.checksum == (try SnapshotEnvelope.checksum(for: saved.archive)))
    }

    @Test func legacySchema4ArchiveStillRejectsAForgedChecksum() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 0x7C, count: 32)
        let fixture = makeRailPreparedChecksumArchive()
        let legacy = try makeLegacySchema4EnvelopeData(archive: fixture.archive)
        var object = try #require(
            JSONSerialization.jsonObject(with: legacy.data) as? [String: Any]
        )
        object["checksum"] = "forged"
        let forged = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let store = SnapshotStore(
            directory: directory,
            keyProvider: FixedSnapshotKeyProvider(key: key)
        )
        try SnapshotCrypto.seal(forged, keyData: key).write(to: store.committedFileURL)

        await #expect(throws: SnapshotStoreError.checksumMismatch) {
            try await store.load(expected: .init(
                protocolVersion: 1,
                rulesetVersion: "rules-v1",
                roomID: fixture.archive.roomID,
                recipientID: GameCore.PlayerID(rawValue: "host"),
                role: .host
            ))
        }
    }

    @Test func verifiedCompleteSchema4ArchiveLoadsAndMigratesToSchema5() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 0x7D, count: 32)
        let catalog = try verifiedCatalog()
        let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
        let hostID = GameCore.PlayerID(rawValue: "host")
        let roomID = GameCore.RoomID(rawValue: "VERIFIED-SCHEMA4")
        let archive = try await makeCompleteHostArchive(
            roomID: roomID,
            hostID: hostID,
            catalog: catalog,
            tokenStore: tokenStore
        )
        let legacy = try makeLegacySchema4EnvelopeData(archive: archive)
        let store = SnapshotStore(
            directory: directory,
            keyProvider: FixedSnapshotKeyProvider(key: key),
            verifiedCatalog: catalog
        )
        try SnapshotCrypto.seal(legacy.data, keyData: key).write(to: store.committedFileURL)

        let loaded = try await store.load(
            expected: .init(
                protocolVersion: 2,
                rulesetVersion: catalog.catalog.rulesetVersion,
                roomID: roomID,
                recipientID: hostID,
                role: .host
            ),
            requiresCurrentSchema: true
        )
        #expect(loaded == archive)

        let migratedData = try SnapshotCrypto.open(
            Data(contentsOf: store.committedFileURL),
            keyData: key
        )
        let migrated = try JSONDecoder().decode(SnapshotEnvelope.self, from: migratedData)
        #expect(migrated.schemaVersion == 5)
        #expect(migrated.checksum == (try SnapshotEnvelope.checksum(for: migrated.archive)))
    }

    @Test func verifiedCatalogRejectsMalformedCompleteAuthorityStateOnSaveRestoreAndListing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try verifiedCatalog()
        let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
        let hostID = GameCore.PlayerID(rawValue: "host")
        let roomID = GameCore.RoomID(rawValue: "MALFORMED-AUTHORITY")
        let complete = try await makeCompleteHostArchive(
            roomID: roomID, hostID: hostID, catalog: catalog, tokenStore: tokenStore
        )
        guard case .host(let completeHost) = complete.payload else {
            Issue.record("Expected host archive")
            return
        }
        let base = try #require(completeHost.gameState)
        let tokens: [GameCore.PlayerID: GameCore.ReconnectToken] = [
            hostID: .init(rawValue: "host-secret"),
            player: .init(rawValue: "guest-secret"),
        ]
        let mutations: [(String, (inout GameCore.GameState) -> Void)] = [
            ("cash", { $0.players[0].cash = -1 }),
            ("stack", { $0.players[0].industryStacks.removeLast() }),
            ("topology", { $0.placedLinks.append(.init(routeID: "forged-route", ownerID: hostID, era: .canal)) }),
            ("market", { $0.coalMarket.slots[0].price = Int.max }),
            ("resource-total", { $0.publicSupply.iron -= 1 }),
            ("round-overflow", { $0.roundNumber = $0.canalRoundCapacity + 1 }),
            ("card-loss", { $0.players[0].hand.removeFirst() }),
            ("card-identity", {
                let card = $0.players[0].hand[0]
                $0.players[0].hand[0] = .init(
                    id: "forged-instance-id", definitionID: card.definitionID
                )
            }),
            ("active-seat", { $0.activePlayerID = $0.playerOrder[1] }),
            ("first-canal-budget", { $0.actionsRemaining = 2 }),
            ("forced-sale-phase", {
                $0.actionsRemaining = 0
                $0.roundIncomeCursor = 0
                $0.turnPhase = .forcedSale(.init(
                    playerID: $0.playerOrder[0], shortfall: 1,
                    eligiblePlacementIDs: ["missing"]
                ))
            }),
            ("resource-overflow", {
                $0.boardIndustryPlacements.append(.init(
                    locationID: "dudley", slotIndex: 0, ownerID: hostID,
                    tile: .init(id: "forged-coal", industryDefinitionID: "coal-mine", level: 1),
                    resourceCount: Int.max
                ))
            }),
            ("completeness", { $0.authorityCompleteness = nil }),
        ]

        func archive(_ state: GameCore.GameState, sequence: UInt64) throws -> SessionArchive {
            let engine = try state.makeHostEngine(
                roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
            )
            return .host(
                protocolVersion: 1, rulesetVersion: catalog.catalog.rulesetVersion,
                recipientID: hostID, state: engine.state, gameState: engine.gameState,
                eventWindows: [:], tokenReferences: [
                    .init(roomID: roomID, playerID: hostID),
                    .init(roomID: roomID, playerID: player),
                ], peersNeedingRecovery: [], commitSequence: sequence
            )
        }

        for (index, mutation) in mutations.enumerated() {
            var malformed = base
            mutation.1(&malformed)
            let value = try archive(malformed, sequence: UInt64(index + 1))
            let key = FixedSnapshotKeyProvider(key: Data(repeating: UInt8(index + 1), count: 32))
            let store = SnapshotStore(
                directory: directory.appendingPathComponent(mutation.0),
                keyProvider: key,
                verifiedCatalog: catalog
            )
            await #expect(throws: SnapshotStoreError.invalidAuthorityState) {
                try await store.save(value)
            }
            try writeUnchecked(value, key: key.key, to: store.committedFileURL)
            await #expect(throws: SnapshotStoreError.invalidAuthorityState) {
                try await store.load(expected: .init(
                    protocolVersion: 1, rulesetVersion: catalog.catalog.rulesetVersion,
                    roomID: roomID, recipientID: hostID, role: .host
                ))
            }
            await #expect(throws: RecoveryError.invalidMaterial) {
                _ = try await RecoveryCoordinator(tokenStore: tokenStore).restoreHost(
                    archive: value, expectedHostID: hostID, catalog: catalog
                )
            }
        }

        var malformed = base
        let listedCard = malformed.players[0].hand[0]
        malformed.players[0].hand[0] = .init(
            id: "forged-listed-instance", definitionID: listedCard.definitionID
        )
        let keyData = Data(repeating: 0x6D, count: 32)
        let factory = SessionPersistenceFactory(
            baseDirectory: directory, tokenStore: tokenStore,
            keyProvider: FixedSnapshotKeyProvider(key: keyData)
        )
        let listingStore = SnapshotStore(
            directory: factory.directory(roomID: roomID, playerID: hostID),
            keyProvider: FixedSnapshotKeyProvider(key: keyData)
        )
        try writeUnchecked(try archive(malformed, sequence: 10), key: keyData, to: listingStore.committedFileURL)
        #expect(try await factory.recoverableHostRooms(catalog: catalog).isEmpty)
    }

    @Test func substituteProductionTotalsSaveLoadListRestoreAndAcceptNextAction() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try verifiedCatalog()
        let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
        let hostID = GameCore.PlayerID(rawValue: "host")
        let roomID = GameCore.RoomID(rawValue: "SUBSTITUTE-TOTALS")
        let complete = try await makeCompleteHostArchive(
            roomID: roomID, hostID: hostID, catalog: catalog, tokenStore: tokenStore
        )
        guard case .host(let hostArchive) = complete.payload else {
            Issue.record("Expected host archive")
            return
        }
        var state = try #require(hostArchive.gameState)
        let ownerIndex = try #require(state.players.firstIndex(where: { $0.id == hostID }))

        func moveTileToBoard(
            industryID: String,
            locationID: String,
            slotIndex: Int,
            resourceCount: Int
        ) throws {
            let stackIndex = try #require(state.players[ownerIndex].industryStacks.firstIndex(where: {
                $0.industryDefinitionID == industryID
            }))
            let tile = try #require(state.players[ownerIndex].industryStacks[stackIndex].tiles.first)
            state.players[ownerIndex].industryStacks[stackIndex].tiles.removeFirst()
            state.boardIndustryPlacements.append(.init(
                locationID: locationID, slotIndex: slotIndex, ownerID: hostID,
                tile: tile, resourceCount: resourceCount
            ))
        }

        try moveTileToBoard(
            industryID: "coal-mine", locationID: "dudley", slotIndex: 0, resourceCount: 2
        )
        try moveTileToBoard(
            industryID: "iron-works", locationID: "coalbrookdale", slotIndex: 1, resourceCount: 4
        )
        let coalTotal = state.publicSupply.coal
            + state.coalMarket.slots.filter(\.hasCube).count
            + state.boardIndustryPlacements.filter {
                $0.tile.industryDefinitionID == "coal-mine"
            }.reduce(0) { $0 + $1.resourceCount }
        let ironTotal = state.publicSupply.iron
            + state.ironMarket.slots.filter(\.hasCube).count
            + state.boardIndustryPlacements.filter {
                $0.tile.industryDefinitionID == "iron-works"
            }.reduce(0) { $0 + $1.resourceCount }
        #expect(coalTotal == 32)
        #expect(ironTotal == 22)
        #expect(GameCore.GameStateAuthorityValidator.isValid(state, catalog: catalog))

        let tokens: [GameCore.PlayerID: GameCore.ReconnectToken] = [
            hostID: .init(rawValue: "host-secret"),
            player: .init(rawValue: "guest-secret"),
        ]
        let engine = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        let archive = SessionArchive.host(
            protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion,
            recipientID: hostID, state: engine.state, gameState: engine.gameState,
            eventWindows: [:], tokenReferences: hostArchive.tokenReferences,
            peersNeedingRecovery: [], commitSequence: 1
        )
        let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x32, count: 32))
        let factory = SessionPersistenceFactory(
            baseDirectory: directory, tokenStore: tokenStore, keyProvider: key
        )
        let store = SnapshotStore(
            directory: factory.directory(roomID: roomID, playerID: hostID),
            keyProvider: key, verifiedCatalog: catalog
        )
        try await store.save(archive)
        let loaded = try await store.load(expected: .init(
            protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion,
            roomID: roomID, recipientID: hostID, role: .host
        ))
        #expect(loaded == archive)
        #expect(try await factory.recoverableHostRooms(catalog: catalog).map(\.roomID) == [roomID])

        let restored = try await RecoveryCoordinator(tokenStore: tokenStore).restoreHost(
            archive: loaded, expectedHostID: hostID, catalog: catalog
        )
        var restoredEngine = try restored.gameState.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        let activeID = try #require(restoredEngine.gameState.activePlayerID)
        let cardID = try #require(restoredEngine.gameState.players.first(where: {
            $0.id == activeID
        })?.hand.first?.id)
        let beforeVersion = restoredEngine.gameState.authoritativeVersion
        let result = restoredEngine.submit(.init(
            protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion,
            roomID: roomID, senderID: activeID,
            reconnectToken: try #require(tokens[activeID]), baseVersion: beforeVersion,
            payload: .pass(.init(cardID: cardID))
        ), catalog: catalog)
        guard case .accepted = result else {
            Issue.record("Expected restored substitute-production state to accept the next action")
            return
        }
        #expect(restoredEngine.gameState.authoritativeVersion.rawValue == beforeVersion.rawValue + 1)
    }

    @Test func schemaTwoHostArchiveIsNotListedAsNormallyRecoverable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try verifiedCatalog()
        let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
        let hostID = GameCore.PlayerID(rawValue: "host")
        let roomID = GameCore.RoomID(rawValue: "SCHEMA-TWO-LISTING")
        let complete = try await makeCompleteHostArchive(
            roomID: roomID, hostID: hostID, catalog: catalog, tokenStore: tokenStore
        )
        let legacy = try archiveByRemovingGameState(from: complete)
        var envelope = try SnapshotEnvelope(archive: legacy)
        envelope.schemaVersion = 2
        let keyData = Data(repeating: 0x2D, count: 32)
        let factory = SessionPersistenceFactory(
            baseDirectory: directory, tokenStore: tokenStore,
            keyProvider: FixedSnapshotKeyProvider(key: keyData)
        )
        let store = SnapshotStore(
            directory: factory.directory(roomID: roomID, playerID: hostID),
            keyProvider: FixedSnapshotKeyProvider(key: keyData)
        )
        try FileManager.default.createDirectory(
            at: store.committedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encrypted = try SnapshotCrypto.seal(
            JSONEncoder.canonical.encode(envelope), keyData: keyData
        )
        try encrypted.write(to: store.committedFileURL)

        for _ in 0..<3 {
            #expect(try await factory.recoverableHostRooms(catalog: catalog).isEmpty)
        }
        #expect(FileManager.default.fileExists(atPath: store.committedFileURL.path))
    }

    @Test func verifiedCoordinatorKeepsSchemaTwoArchiveWithoutCountingOrDeletingIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try verifiedCatalog()
        let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
        let tracker = SessionRecoveryFailureTracker()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let roomID = GameCore.RoomID(rawValue: "SCHEMA-TWO-COORDINATOR")
        let complete = try await makeCompleteHostArchive(
            roomID: roomID, hostID: hostID, catalog: catalog, tokenStore: tokenStore
        )
        var envelope = try SnapshotEnvelope(archive: try archiveByRemovingGameState(from: complete))
        envelope.schemaVersion = 2
        let keyData = Data(repeating: 0x2E, count: 32)
        let factory = SessionPersistenceFactory(
            baseDirectory: directory, tokenStore: tokenStore,
            keyProvider: FixedSnapshotKeyProvider(key: keyData), failureTracker: tracker
        )
        let store = SnapshotStore(
            directory: factory.directory(roomID: roomID, playerID: hostID),
            keyProvider: FixedSnapshotKeyProvider(key: keyData)
        )
        try FileManager.default.createDirectory(
            at: store.committedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try SnapshotCrypto.seal(
            JSONEncoder.canonical.encode(envelope), keyData: keyData
        ).write(to: store.committedFileURL)
        let reference = RoomTokenReference(roomID: roomID, playerID: hostID)
        let configuration = SessionCoordinator.Configuration(
            protocolVersion: 1, rulesetVersion: catalog.catalog.rulesetVersion,
            roomID: roomID, playerID: hostID,
            reconnectToken: .init(rawValue: "host-secret"), hostPlayerID: hostID
        )

        for _ in 0..<3 {
            _ = try await factory.makeCoordinator(
                configuration: configuration, role: .host,
                transport: LoopbackTransportHub().makeTransport(peerID: hostID),
                rulesMode: .verified(catalog)
            )
        }

        #expect(await tracker.failureCount(for: reference) == 0)
        #expect(FileManager.default.fileExists(atPath: store.committedFileURL.path))
    }

    @Test func verifiedProtocolTwoIgnoresProtocolOneArchiveWithoutFallbackOrDeletion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try verifiedCatalog()
        let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
        let tracker = SessionRecoveryFailureTracker()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let roomID = GameCore.RoomID(rawValue: "PROTOCOL-ONE-PRESERVED")
        let complete = try await makeCompleteHostArchive(
            roomID: roomID, hostID: hostID, catalog: catalog, tokenStore: tokenStore
        )
        let legacy = SessionArchive(
            protocolVersion: 1, rulesetVersion: complete.rulesetVersion,
            roomID: complete.roomID, recipientID: complete.recipientID,
            role: complete.role, authoritativeVersion: complete.authoritativeVersion,
            commitSequence: complete.commitSequence, payload: complete.payload
        )
        let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x2F, count: 32))
        let factory = SessionPersistenceFactory(
            baseDirectory: directory, tokenStore: tokenStore,
            keyProvider: key, failureTracker: tracker
        )
        let store = SnapshotStore(
            directory: factory.directory(roomID: roomID, playerID: hostID),
            keyProvider: key, verifiedCatalog: catalog
        )
        try await store.save(legacy)

        for _ in 0..<3 {
            #expect(try await factory.recoverableHostRooms(catalog: catalog).isEmpty)
            _ = try await factory.makeCoordinator(
                configuration: .init(
                    protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion,
                    roomID: roomID, playerID: hostID,
                    reconnectToken: .init(rawValue: "replacement-must-not-win"),
                    hostPlayerID: hostID
                ),
                role: .host,
                transport: LoopbackTransportHub().makeTransport(peerID: hostID),
                rulesMode: .verified(catalog)
            )
        }

        #expect(await tracker.failureCount(for: .init(roomID: roomID, playerID: hostID)) == 0)
        #expect(FileManager.default.fileExists(atPath: store.committedFileURL.path))
        #expect(try await tokenStore.load(roomID: roomID, playerID: hostID) != nil)
    }

    @Test func incompatibleRulesetArchiveIsNotCountedAsCorruptOrDeleted() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
        let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x23, count: 32))
        let factory = SessionPersistenceFactory(
            baseDirectory: directory, tokenStore: tokenStore, keyProvider: key
        )
        let catalog = try verifiedCatalog()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let roomID = GameCore.RoomID(rawValue: "OLD-RULESET")
        try await tokenStore.save(.init(
            roomID: roomID, playerID: hostID, reconnectToken: .init(rawValue: "host-secret")
        ))
        let store = SnapshotStore(
            directory: factory.directory(roomID: roomID, playerID: hostID), keyProvider: key
        )
        try await store.save(try await makeHostArchive(roomID: roomID, hostID: hostID))

        for _ in 0..<3 {
            #expect(try await factory.recoverableHostRooms(catalog: catalog).isEmpty)
        }
        #expect(FileManager.default.fileExists(atPath: store.committedFileURL.path))
        #expect(try await tokenStore.load(roomID: roomID, playerID: hostID) != nil)
    }

    @Test func gameDataLoadAndValidationFailuresMapToStableNearbyUIError() {
        let missing = GameCore.GameDataLoadError.bundledResourceMissing("manifest.json")
        let invalid = GameCore.GameDataLoadError.validationFailed([])

        #expect(NearbyPreflight.issue(for: missing) == .gameDataUnavailable)
        #expect(NearbyPreflight.issue(for: invalid) == .gameDataUnavailable)
        #expect(NearbyPreflight.issue(for: SessionCoordinator.Error.dataUnavailable) == .gameDataUnavailable)
        #expect(NearbyPreflightIssue.gameDataUnavailable.title == "游戏数据不可用")
        #expect(NearbyPreflightIssue.gameDataUnavailable.recoveryMessage.contains("规则数据未通过校验"))
    }

    @MainActor
    @Test func appScopedPersistenceStateSurvivesNearbyPageExitAndReentry() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
        let factory = SessionPersistenceFactory(
            baseDirectory: directory,
            tokenStore: tokenStore,
            keyProvider: FixedSnapshotKeyProvider(key: Data(repeating: 0x21, count: 32))
        )
        let state = NearbyPersistenceState(persistenceFactory: factory)
        let hostID = GameCore.PlayerID(rawValue: "host")
        let roomID = GameCore.RoomID(rawValue: "PAGE-REENTRY")
        try await tokenStore.save(.init(
            roomID: roomID, playerID: hostID, reconnectToken: .init(rawValue: "keep-token")
        ))
        let corruptedURL = SnapshotStore(
            directory: factory.directory(roomID: roomID, playerID: hostID),
            keyProvider: FixedSnapshotKeyProvider(key: Data(repeating: 0x21, count: 32))
        ).committedFileURL
        try FileManager.default.createDirectory(
            at: corruptedURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("corrupted".utf8).write(to: corruptedURL)

        #expect(try await state.persistenceFactory.recoverableFixtureOnlyHostRooms().isEmpty)
        let firstEntry = NearbyRoomView(persistenceState: state, onNavigate: { _ in })
        #expect(try await state.persistenceFactory.recoverableFixtureOnlyHostRooms().isEmpty)
        let secondEntry = NearbyRoomView(persistenceState: state, onNavigate: { _ in })

        #expect(firstEntry.persistenceTrackerIdentity == factory.recoveryTrackerIdentity)
        #expect(secondEntry.persistenceTrackerIdentity == firstEntry.persistenceTrackerIdentity)
        await #expect(throws: RecoveryError.returnToLobby("recovery-material-invalid")) {
            _ = try await state.persistenceFactory.recoverableFixtureOnlyHostRooms()
        }
        #expect(!FileManager.default.fileExists(atPath: corruptedURL.path))
    }

    @Test func guestSnapshotUsesRealAuthenticatedEncryptionAndRoundTripsOnlyItsRecipientProjection() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 0x2A, count: 32)
        let store = SnapshotStore(directory: directory, keyProvider: FixedSnapshotKeyProvider(key: key))
        let snapshot = makeSnapshot(recipient: player, opponentHand: nil, version: 4)
        let archive = SessionArchive.guest(
            protocolVersion: 1,
            rulesetVersion: "rules-v1",
            hostPlayerID: .init(rawValue: "host"),
            snapshot: snapshot,
            eventWindow: [],
            tokenReference: .init(roomID: room, playerID: player),
            commitSequence: 7
        )

        try await store.save(archive)
        let loaded = try await store.load(expected: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            recipientID: player, role: .guest
        ))

        #expect(loaded == archive)
        let encrypted = try Data(contentsOf: store.committedFileURL)
        #expect(!encrypted.contains(Data("card-private".utf8)))
        guard case let .guest(payload) = loaded.payload else {
            Issue.record("Expected guest payload")
            return
        }
        #expect(payload.snapshot.players.first(where: { $0.id != player })?.hand == nil)
    }

    @Test func snapshotStoreRejectsTamperTruncationAndWrongKey() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 0x11, count: 32)
        let store = SnapshotStore(directory: directory, keyProvider: FixedSnapshotKeyProvider(key: key))
        let archive = makeGuestArchive(sequence: 1)
        try await store.save(archive)
        let url = store.committedFileURL
        let original = try Data(contentsOf: url)

        var tampered = original
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        try tampered.write(to: url)
        await #expect(throws: SnapshotStoreError.authenticationFailed) {
            try await store.load(expected: expectedGuest())
        }

        try original.prefix(8).write(to: url)
        await #expect(throws: SnapshotStoreError.truncated) {
            try await store.load(expected: expectedGuest())
        }

        try original.write(to: url)
        let wrongKeyStore = SnapshotStore(
            directory: directory,
            keyProvider: FixedSnapshotKeyProvider(key: Data(repeating: 0x22, count: 32))
        )
        await #expect(throws: SnapshotStoreError.authenticationFailed) {
            try await wrongKeyStore.load(expected: expectedGuest())
        }
    }

    @Test func snapshotStoreRejectsSchemaProtocolRulesetRecipientAndChecksumMismatch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 0x33, count: 32)
        let provider = FixedSnapshotKeyProvider(key: key)
        let store = SnapshotStore(directory: directory, keyProvider: provider)
        try await store.save(makeGuestArchive(sequence: 2))

        let mismatches: [(SnapshotExpectation, SnapshotStoreError)] = [
            (.init(protocolVersion: 2, rulesetVersion: "rules-v1", roomID: room, recipientID: player, role: .guest), .protocolMismatch),
            (.init(protocolVersion: 1, rulesetVersion: "rules-v2", roomID: room, recipientID: player, role: .guest), .rulesetMismatch),
            (.init(protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room, recipientID: .init(rawValue: "other"), role: .guest), .recipientMismatch),
        ]
        for (expectation, error) in mismatches {
            await #expect(throws: error) { try await store.load(expected: expectation) }
        }

        let url = store.committedFileURL
        let decrypted = try SnapshotCrypto.open(try Data(contentsOf: url), keyData: key)
        var envelope = try JSONDecoder().decode(SnapshotEnvelope.self, from: decrypted)
        envelope.checksum = "forged"
        let forged = try SnapshotCrypto.seal(try JSONEncoder.canonical.encode(envelope), keyData: key)
        try forged.write(to: url)
        await #expect(throws: SnapshotStoreError.checksumMismatch) {
            try await store.load(expected: expectedGuest())
        }

        envelope.schemaVersion = 99
        envelope.checksum = try SnapshotEnvelope.checksum(for: envelope.archive)
        let future = try SnapshotCrypto.seal(try JSONEncoder.canonical.encode(envelope), keyData: key)
        try future.write(to: url)
        await #expect(throws: SnapshotStoreError.schemaMismatch) {
            try await store.load(expected: expectedGuest())
        }
    }

    @Test func guestArchiveRejectsNestedEventThatLeaksAnOpponentHandDespiteValidOuterChecksum() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 0x34, count: 32)
        let store = SnapshotStore(directory: directory, keyProvider: FixedSnapshotKeyProvider(key: key))
        let original = makeRecoveryEnvelope(version: 4, persistedState: .init(
            roomID: room, players: [], activePlayerID: player, turn: 5, actionNumber: 4,
            authoritativeVersion: .init(rawValue: 4), discardPile: []
        ))
        guard case let .clientEvent(clientEvent) = original.payload else { return }
        let leakedSnapshot = makeSnapshot(recipient: player, opponentHand: ["opponent-secret"], version: 4)
        let leaked = SessionProtocol.SessionEnvelope(
            protocolVersion: original.protocolVersion, rulesetVersion: original.rulesetVersion,
            roomID: original.roomID, messageID: original.messageID, senderID: original.senderID,
            recipientID: original.recipientID, authoritativeVersion: original.authoritativeVersion,
            payload: .clientEvent(.init(event: clientEvent.event, snapshot: leakedSnapshot))
        )
        let archive = SessionArchive.guest(
            protocolVersion: 1, rulesetVersion: "rules-v1",
            hostPlayerID: .init(rawValue: "host"),
            snapshot: makeSnapshot(recipient: player, opponentHand: nil, version: 4),
            eventWindow: [leaked], tokenReference: .init(roomID: room, playerID: player),
            commitSequence: 4
        )
        let encrypted = try SnapshotCrypto.seal(
            JSONEncoder.canonical.encode(SnapshotEnvelope(archive: archive)), keyData: key
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encrypted.write(to: store.committedFileURL)

        await #expect(throws: SnapshotStoreError.privacyViolation) {
            try await store.load(expected: expectedGuest())
        }
    }

    @Test func guestArchiveRejectsNestedEventWhoseActorIsOutsideItsSnapshotRoster() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 0x35, count: 32)
        let store = SnapshotStore(directory: directory, keyProvider: FixedSnapshotKeyProvider(key: key))
        let original = makeRecoveryEnvelope(version: 4, persistedState: .init(
            roomID: room, players: [], activePlayerID: player, turn: 5, actionNumber: 4,
            authoritativeVersion: .init(rawValue: 4), discardPile: []
        ))
        guard case let .clientEvent(clientEvent) = original.payload else { return }
        let unknownEvent = GameCore.AuthoritativeGameEvent(
            roomID: clientEvent.event.roomID, actor: .init(rawValue: "unknown-actor"),
            previousVersion: clientEvent.event.previousVersion, version: clientEvent.event.version,
            actionNumber: clientEvent.event.actionNumber, payload: clientEvent.event.payload
        )
        let unknown = SessionProtocol.SessionEnvelope(
            protocolVersion: original.protocolVersion, rulesetVersion: original.rulesetVersion,
            roomID: original.roomID, messageID: original.messageID, senderID: original.senderID,
            recipientID: original.recipientID, authoritativeVersion: original.authoritativeVersion,
            payload: .clientEvent(.init(event: unknownEvent, snapshot: clientEvent.snapshot))
        )
        let archive = SessionArchive.guest(
            protocolVersion: 1, rulesetVersion: "rules-v1",
            hostPlayerID: .init(rawValue: "host"),
            snapshot: makeSnapshot(recipient: player, opponentHand: nil, version: 4),
            eventWindow: [unknown], tokenReference: .init(roomID: room, playerID: player),
            commitSequence: 4
        )
        let encrypted = try SnapshotCrypto.seal(
            JSONEncoder.canonical.encode(SnapshotEnvelope(archive: archive)), keyData: key
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encrypted.write(to: store.committedFileURL)

        await #expect(throws: SnapshotStoreError.privacyViolation) {
            try await store.load(expected: expectedGuest())
        }
    }

    @Test func guestArchivePersistsHostIdentityAndRejectsForgedNestedSenderAfterReencryption() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 0x36, count: 32)
        let hostID = GameCore.PlayerID(rawValue: "host")
        let valid = makeRecoveryEnvelope(version: 4, persistedState: .init(
            roomID: room, players: [], activePlayerID: player, turn: 5, actionNumber: 4,
            authoritativeVersion: .init(rawValue: 4), discardPile: []
        ))
        let forged = SessionProtocol.SessionEnvelope(
            protocolVersion: valid.protocolVersion, rulesetVersion: valid.rulesetVersion,
            roomID: valid.roomID, messageID: valid.messageID,
            senderID: .init(rawValue: "attacker"), recipientID: valid.recipientID,
            authoritativeVersion: valid.authoritativeVersion, payload: valid.payload
        )
        let archive = SessionArchive.guest(
            protocolVersion: 1, rulesetVersion: "rules-v1", hostPlayerID: hostID,
            snapshot: makeSnapshot(recipient: player, opponentHand: nil, version: 4),
            eventWindow: [forged], tokenReference: .init(roomID: room, playerID: player),
            commitSequence: 4
        )
        let store = SnapshotStore(directory: directory, keyProvider: FixedSnapshotKeyProvider(key: key))
        try writeUnchecked(archive, key: key, to: store.committedFileURL)

        await #expect(throws: SnapshotStoreError.privacyViolation) {
            try await store.load(expected: expectedGuest())
        }
        guard case let .guest(payload) = archive.payload else { return }
        #expect(payload.hostPlayerID == hostID)
    }

    @Test func guestArchiveRejectsOutOfOrderGappedAndNonfinalEventWindows() async throws {
        let state = GameCore.AuthoritativeGameState(
            roomID: room, players: [], activePlayerID: player, turn: 5, actionNumber: 4,
            authoritativeVersion: .init(rawValue: 4), discardPile: []
        )
        let malformedWindows = [
            [makeRecoveryEnvelope(version: 4, persistedState: state), makeRecoveryEnvelope(version: 3, persistedState: state)],
            [makeRecoveryEnvelope(version: 2, persistedState: state), makeRecoveryEnvelope(version: 4, persistedState: state)],
            [makeRecoveryEnvelope(version: 2, persistedState: state), makeRecoveryEnvelope(version: 3, persistedState: state)],
        ]

        for (index, window) in malformedWindows.enumerated() {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = Data(repeating: UInt8(0x50 + index), count: 32)
            let archive = SessionArchive.guest(
                protocolVersion: 1, rulesetVersion: "rules-v1",
                hostPlayerID: .init(rawValue: "host"),
                snapshot: makeSnapshot(recipient: player, opponentHand: nil, version: 4),
                eventWindow: window, tokenReference: .init(roomID: room, playerID: player),
                commitSequence: 7
            )
            let store = SnapshotStore(directory: directory, keyProvider: FixedSnapshotKeyProvider(key: key))
            try writeUnchecked(archive, key: key, to: store.committedFileURL)
            await #expect(throws: SnapshotStoreError.privacyViolation) {
                try await store.load(expected: expectedGuest())
            }
        }
    }

    @Test func hostArchiveRejectsMalformedRecipientWindowsAndRosterReferences() async throws {
        let fixture = try await makeRecoveryFixture(windowVersions: [3, 4], persistedVersion: 4)
        guard case let .host(validHost) = fixture.archive.payload,
              let validEnvelope = validHost.eventWindows[player]?.last,
              case let .clientEvent(validEvent) = validEnvelope.payload else {
            Issue.record("Expected valid host fixture")
            return
        }
        let hostID = GameCore.PlayerID(rawValue: "host")
        let unknownID = GameCore.PlayerID(rawValue: "unknown")
        func envelope(
            protocolVersion: Int = 1,
            rulesetVersion: String = "rules-v1",
            roomID: GameCore.RoomID? = nil,
            senderID: GameCore.PlayerID? = nil,
            recipientID: GameCore.PlayerID? = nil,
            clientEvent: GameCore.ClientEvent? = nil
        ) -> SessionProtocol.SessionEnvelope {
            .init(
                protocolVersion: protocolVersion, rulesetVersion: rulesetVersion,
                roomID: roomID ?? room, messageID: .init(rawValue: UUID().uuidString),
                senderID: senderID ?? hostID, recipientID: recipientID ?? player,
                authoritativeVersion: (clientEvent ?? validEvent).event.version,
                payload: .clientEvent(clientEvent ?? validEvent)
            )
        }
        func replacingSnapshot(
            _ snapshot: GameCore.ViewSnapshot,
            actor: GameCore.PlayerID? = nil,
            transitions: [GameCore.GameTransitionEvent]? = nil
        ) -> GameCore.ClientEvent {
            .init(event: .init(
                roomID: validEvent.event.roomID, actor: actor ?? validEvent.event.actor,
                previousVersion: validEvent.event.previousVersion, version: validEvent.event.version,
                actionNumber: validEvent.event.actionNumber, payload: validEvent.event.payload,
                transitions: transitions ?? validEvent.event.transitions
            ), snapshot: snapshot)
        }
        let badChecksumSnapshot = GameCore.ViewSnapshot(
            roomID: validEvent.snapshot.roomID, recipient: validEvent.snapshot.recipient,
            players: validEvent.snapshot.players, activePlayerID: validEvent.snapshot.activePlayerID,
            turn: validEvent.snapshot.turn, actionNumber: validEvent.snapshot.actionNumber,
            authoritativeVersion: validEvent.snapshot.authoritativeVersion,
            discardPile: validEvent.snapshot.discardPile, checksum: "forged"
        )
        let leakedSnapshot = makeSnapshot(recipient: player, opponentHand: ["leak"], version: 4)
        let extraRosterPlayers = validEvent.snapshot.players + [
            .init(id: unknownID, handCount: 0, hand: nil)
        ]
        let extraRosterSnapshot = GameCore.ViewSnapshot(
            roomID: validEvent.snapshot.roomID, recipient: validEvent.snapshot.recipient,
            players: extraRosterPlayers, activePlayerID: validEvent.snapshot.activePlayerID,
            turn: validEvent.snapshot.turn, actionNumber: validEvent.snapshot.actionNumber,
            authoritativeVersion: validEvent.snapshot.authoritativeVersion,
            discardPile: validEvent.snapshot.discardPile,
            checksum: try GameCore.snapshotChecksum(
                roomID: validEvent.snapshot.roomID, recipient: validEvent.snapshot.recipient,
                players: extraRosterPlayers, activePlayerID: validEvent.snapshot.activePlayerID,
                turn: validEvent.snapshot.turn, actionNumber: validEvent.snapshot.actionNumber,
                authoritativeVersion: validEvent.snapshot.authoritativeVersion,
                discardPile: validEvent.snapshot.discardPile
            )
        )
        let gap = [
            makeRecoveryEnvelope(version: 2, persistedState: fixtureRestoredState(fixture.archive)),
            makeRecoveryEnvelope(version: 4, persistedState: fixtureRestoredState(fixture.archive)),
        ]
        let reversed = Array((validHost.eventWindows[player] ?? []).reversed())
        let validGameState = try #require(validHost.gameState)
        func hostArchive(
            state: PersistedAuthoritativeGameState? = nil,
            eventWindows: [GameCore.PlayerID: [SessionProtocol.SessionEnvelope]],
            tokenReferences: [RoomTokenReference]? = nil,
            peersNeedingRecovery: Set<GameCore.PlayerID> = []
        ) -> HostSessionArchive {
            .init(
                authoritativeState: state ?? validHost.authoritativeState,
                gameState: validGameState,
                eventWindows: eventWindows,
                tokenReferences: tokenReferences ?? validHost.tokenReferences,
                peersNeedingRecovery: peersNeedingRecovery
            )
        }

        var malformedHosts: [HostSessionArchive] = [
            hostArchive(eventWindows: [hostID: [validEnvelope]]),
            hostArchive(eventWindows: [player: [envelope(senderID: player)]]),
            hostArchive(eventWindows: [player: [envelope(protocolVersion: 2)]]),
            hostArchive(eventWindows: [player: [envelope(rulesetVersion: "rules-v2")]]),
            hostArchive(eventWindows: [player: [envelope(roomID: .init(rawValue: "OTHER"))]]),
            hostArchive(eventWindows: [player: [envelope(clientEvent: replacingSnapshot(badChecksumSnapshot))]]),
            hostArchive(eventWindows: [player: [envelope(clientEvent: replacingSnapshot(leakedSnapshot))]]),
            hostArchive(eventWindows: [player: [envelope(clientEvent: replacingSnapshot(extraRosterSnapshot))]]),
            hostArchive(eventWindows: [player: [envelope(clientEvent: replacingSnapshot(validEvent.snapshot, actor: unknownID))]]),
            hostArchive(eventWindows: [player: [envelope(clientEvent: replacingSnapshot(
                validEvent.snapshot,
                transitions: [.forcedSaleRequired(.init(
                    playerID: hostID, shortfall: 5, eligiblePlacementIDs: ["private-placement"]
                ))]
            ))]]),
            hostArchive(eventWindows: [player: gap]),
            hostArchive(eventWindows: [player: reversed]),
            hostArchive(eventWindows: [player: [makeRecoveryEnvelope(version: 3, persistedState: fixtureRestoredState(fixture.archive))]]),
            hostArchive(eventWindows: validHost.eventWindows, tokenReferences: [validHost.tokenReferences[0], validHost.tokenReferences[0]]),
            hostArchive(eventWindows: validHost.eventWindows, tokenReferences: [validHost.tokenReferences[0]]),
            hostArchive(eventWindows: validHost.eventWindows, tokenReferences: validHost.tokenReferences + [.init(roomID: room, playerID: unknownID)]),
            hostArchive(eventWindows: validHost.eventWindows, peersNeedingRecovery: [unknownID]),
        ]
        var unknownActive = validHost.authoritativeState
        unknownActive.activePlayerID = unknownID
        malformedHosts.append(.init(
            authoritativeState: unknownActive,
            gameState: validGameState,
            eventWindows: validHost.eventWindows,
            tokenReferences: validHost.tokenReferences, peersNeedingRecovery: []
        ))

        for (index, host) in malformedHosts.enumerated() {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = Data(repeating: UInt8(0x70 + index), count: 32)
            let archive = SessionArchive(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                recipientID: hostID, role: .host, authoritativeVersion: .init(rawValue: 4),
                commitSequence: 9, payload: .host(host)
            )
            let store = SnapshotStore(directory: directory, keyProvider: FixedSnapshotKeyProvider(key: key))
            try writeUnchecked(archive, key: key, to: store.committedFileURL)
            await #expect(throws: SnapshotStoreError.privacyViolation) {
                try await store.load(expected: .init(
                    protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                    recipientID: hostID, role: .host
                ))
            }
        }
    }

    @Test func concurrentSnapshotSavesCannotLetAnOlderCommitOverwriteANewerCommit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(
            directory: directory,
            keyProvider: FixedSnapshotKeyProvider(key: Data(repeating: 0x44, count: 32))
        )

        async let newer: Void? = try? store.save(makeGuestArchive(sequence: 8))
        async let older: Void? = try? store.save(makeGuestArchive(sequence: 7))
        _ = await (newer, older)

        let loaded = try await store.load(expected: expectedGuest())
        #expect(loaded.commitSequence == 8)
    }

    @Test func aFreshSnapshotStoreCannotOverwriteAHigherDurableCommitWithoutLoadingFirst() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x46, count: 32))
        try await SnapshotStore(directory: directory, keyProvider: key).save(makeGuestArchive(sequence: 9))

        let relaunchedStore = SnapshotStore(directory: directory, keyProvider: key)
        await #expect(throws: SnapshotStoreError.commitSequenceRollback) {
            try await relaunchedStore.save(makeGuestArchive(sequence: 8))
        }

        #expect(try await relaunchedStore.load(expected: expectedGuest()).commitSequence == 9)
    }

    @Test func sameSnapshotCommitIsIdempotentButDifferentCanonicalContentConflicts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x47, count: 32))
        let first = makeGuestArchive(sequence: 8)
        let store = SnapshotStore(directory: directory, keyProvider: key)
        try await store.save(first)
        try await SnapshotStore(directory: directory, keyProvider: key).save(first)

        let conflicting = SessionArchive.guest(
            protocolVersion: 1, rulesetVersion: "rules-v1",
            hostPlayerID: .init(rawValue: "host"),
            snapshot: makeSnapshot(recipient: player, opponentHand: nil, version: 7),
            eventWindow: [], tokenReference: .init(roomID: room, playerID: player),
            commitSequence: 8
        )
        await #expect(throws: SnapshotStoreError.commitSequenceConflict) {
            try await SnapshotStore(directory: directory, keyProvider: key).save(conflicting)
        }
        #expect(try await store.load(expected: expectedGuest()).authoritativeVersion == .init(rawValue: 8))
    }

    @Test func racingLoadSeesAWholeCommitAndCancellationDoesNotBlockLaterSaves() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(
            directory: directory,
            keyProvider: FixedSnapshotKeyProvider(key: Data(repeating: 0x45, count: 32))
        )
        try await store.save(makeGuestArchive(sequence: 8))

        async let load = store.load(expected: expectedGuest())
        async let save: Void = store.save(makeGuestArchive(sequence: 9))
        let observed = try await load
        try await save
        #expect([8, 9].contains(observed.commitSequence))
        #expect(try await store.load(expected: expectedGuest()).commitSequence == 9)

        let cancelled = Task { try await store.save(makeGuestArchive(sequence: 10)) }
        cancelled.cancel()
        _ = try? await cancelled.value
        try await store.save(makeGuestArchive(sequence: 11))
        #expect(try await store.load(expected: expectedGuest()).commitSequence == 11)
    }

    @Test func interruptedSiblingTempWritePreservesThePreviousCommittedSnapshotAndCleanupIsScoped() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x55, count: 32))
        let goodStore = SnapshotStore(directory: directory, keyProvider: key)
        try await goodStore.save(makeGuestArchive(sequence: 3))
        let unrelated = directory.appendingPathComponent("keep-me.tmp")
        try Data("keep".utf8).write(to: unrelated)

        let interrupted = SnapshotStore(
            directory: directory,
            keyProvider: key,
            fileWriter: InterruptingSnapshotFileWriter()
        )
        await #expect(throws: SnapshotStoreError.writeInterrupted) {
            try await interrupted.save(makeGuestArchive(sequence: 4))
        }

        #expect(try await goodStore.load(expected: expectedGuest()).commitSequence == 3)
        try await goodStore.cleanOrphanTemps()
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(SnapshotStore.temporaryFilePrefix) }.isEmpty)
    }

    @Test func authenticatedRecoveryUsesAContinuousRecipientEventWindowBeforeSnapshotFallback() async throws {
        let fixture = try await makeRecoveryFixture(windowVersions: [3, 4], persistedVersion: 4)
        let result = try await fixture.coordinator.recover(.init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: player, reconnectToken: .init(rawValue: "right-token"),
            hostPlayerID: .init(rawValue: "host"), authenticatedRemotePlayerID: .init(rawValue: "host"),
            fromVersion: .init(rawValue: 2)
        ), from: fixture.archive, schemaVersion: 2)

        guard case let .events(events) = result else {
            Issue.record("Expected continuous event catch-up")
            return
        }
        #expect(events.map(\.authoritativeVersion.rawValue) == [3, 4])
        #expect(events.allSatisfy { $0.recipientID == player })
    }

    @Test func recoveryFallsBackToSnapshotWhenContinuousWindowNamesUnknownEventActor() async throws {
        let fixture = try await makeRecoveryFixture(windowVersions: [3, 4], persistedVersion: 4)
        guard case let .host(hostPayload) = fixture.archive.payload,
              var events = hostPayload.eventWindows[player],
              case let .clientEvent(original) = events[0].payload else { return }
        let unknownEvent = GameCore.AuthoritativeGameEvent(
            roomID: original.event.roomID, actor: .init(rawValue: "unknown-actor"),
            previousVersion: original.event.previousVersion, version: original.event.version,
            actionNumber: original.event.actionNumber, payload: original.event.payload
        )
        events[0].payload = .clientEvent(.init(event: unknownEvent, snapshot: original.snapshot))
        let broken = SessionArchive(
            protocolVersion: fixture.archive.protocolVersion,
            rulesetVersion: fixture.archive.rulesetVersion,
            roomID: fixture.archive.roomID, recipientID: fixture.archive.recipientID, role: .host,
            authoritativeVersion: fixture.archive.authoritativeVersion,
            commitSequence: fixture.archive.commitSequence,
            payload: .host(.init(
                authoritativeState: hostPayload.authoritativeState,
                gameState: try #require(hostPayload.gameState),
                eventWindows: [player: events], tokenReferences: hostPayload.tokenReferences,
                peersNeedingRecovery: hostPayload.peersNeedingRecovery
            ))
        )
        let result = try await fixture.coordinator.recover(.init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: player, reconnectToken: .init(rawValue: "right-token"),
            hostPlayerID: .init(rawValue: "host"), authenticatedRemotePlayerID: .init(rawValue: "host"),
            fromVersion: .init(rawValue: 2)
        ), from: broken, schemaVersion: 2)

        guard case let .snapshot(snapshot) = result else {
            Issue.record("Unknown actors must never be applied from recovery history")
            return
        }
        #expect(snapshot.recipient == player)
    }

    @Test(arguments: [([4], 2), ([2, 4], 2), ([], 0)])
    func oldMissingOrGappedHistoryFallsBackToOnlyTheAuthenticatedRecipientSnapshot(
        versions: [Int],
        fromVersion: Int
    ) async throws {
        let fixture = try await makeRecoveryFixture(windowVersions: versions, persistedVersion: 4)
        let result = try await fixture.coordinator.recover(.init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: player, reconnectToken: .init(rawValue: "right-token"),
            hostPlayerID: .init(rawValue: "host"), authenticatedRemotePlayerID: .init(rawValue: "host"),
            fromVersion: .init(rawValue: fromVersion)
        ), from: fixture.archive, schemaVersion: 2)

        guard case let .snapshot(snapshot) = result else {
            Issue.record("Expected recipient snapshot fallback")
            return
        }
        #expect(snapshot.recipient == player)
        #expect(snapshot.players.allSatisfy { $0.id == player ? $0.hand != nil : $0.hand == nil })
    }

    @Test func currentSchemaForcedSaleFallbackUsesCompleteAuthorityAndRemainsPlayable() async throws {
        let catalog = try verifiedCatalog()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let debtorID = player
        var setup = GameCore.SetupRules(seed: 44)
        var gameState = try setup.makeGame(catalog: catalog, playerIDs: [hostID, debtorID]).state
        let debtorIndex = try #require(gameState.players.firstIndex { $0.id == debtorID })
        let coalIndex = try #require(gameState.players[debtorIndex].industryStacks.firstIndex {
            $0.industryDefinitionID == "coal-mine"
        })
        let ironIndex = try #require(gameState.players[debtorIndex].industryStacks.firstIndex {
            $0.industryDefinitionID == "iron-works"
        })
        let coal = gameState.players[debtorIndex].industryStacks[coalIndex].tiles.removeFirst()
        let iron = gameState.players[debtorIndex].industryStacks[ironIndex].tiles.removeFirst()
        gameState.players[debtorIndex].cash = 0
        gameState.players[debtorIndex].incomePosition = 0
        gameState.boardIndustryPlacements = [
            .init(locationID: "dudley", slotIndex: 0, ownerID: debtorID, tile: coal),
            .init(locationID: "coalbrookdale", slotIndex: 1, ownerID: debtorID, tile: iron),
        ]
        let eligible = gameState.boardIndustryPlacements.map(\.placementID).sorted()
        gameState.activePlayerID = debtorID
        gameState.actionsRemaining = 0
        gameState.roundIncomeCursor = 1
        gameState.turnPhase = .forcedSale(.init(
            playerID: debtorID, shortfall: 10, eligiblePlacementIDs: eligible
        ))
        gameState.actionNumber = 4
        gameState.authoritativeVersion = .init(rawValue: 4)
        repairCardFixture(&gameState, catalog: catalog)
        #expect(GameCore.GameStateAuthorityValidator.isValid(gameState, catalog: catalog))

        let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
        let tokens: [GameCore.PlayerID: GameCore.ReconnectToken] = [
            hostID: .init(rawValue: "host-token"), debtorID: .init(rawValue: "right-token"),
        ]
        for (playerID, token) in tokens {
            try await tokenStore.save(.init(roomID: room, playerID: playerID, reconnectToken: token))
        }
        let engine = try gameState.makeHostEngine(
            roomID: room, reconnectTokens: tokens, protocolVersion: 1
        )
        let debtorSnapshot = try engine.snapshot(for: debtorID)
        let gapEvent = GameCore.AuthoritativeGameEvent(
            roomID: room, actor: hostID, previousVersion: .init(rawValue: 3),
            version: .init(rawValue: 4), actionNumber: 4,
            payload: .passed(discardedCardID: "gap")
        )
        let gapEnvelope = SessionProtocol.SessionEnvelope(
            protocolVersion: 1, rulesetVersion: catalog.catalog.rulesetVersion, roomID: room,
            messageID: .init(rawValue: "gap-4"), senderID: hostID, recipientID: debtorID,
            authoritativeVersion: .init(rawValue: 4),
            payload: .clientEvent(.init(event: gapEvent, snapshot: debtorSnapshot))
        )
        let archive = SessionArchive.host(
            protocolVersion: 1, rulesetVersion: catalog.catalog.rulesetVersion,
            recipientID: hostID, state: engine.state, gameState: engine.gameState,
            eventWindows: [debtorID: [gapEnvelope]],
            tokenReferences: tokens.keys.map { .init(roomID: room, playerID: $0) },
            peersNeedingRecovery: [], commitSequence: 4
        )
        let recovery = RecoveryCoordinator(tokenStore: tokenStore)
        let debtorResult = try await recovery.recover(.init(
            protocolVersion: 1, rulesetVersion: catalog.catalog.rulesetVersion, roomID: room,
            playerID: debtorID, reconnectToken: tokens[debtorID]!, hostPlayerID: hostID,
            authenticatedRemotePlayerID: hostID, fromVersion: .init(rawValue: 2)
        ), from: archive, schemaVersion: SnapshotEnvelope.currentSchemaVersion, catalog: catalog)
        guard case .snapshot(let recoveredDebtor) = debtorResult else {
            Issue.record("Expected gapped history to fall back to the complete authority snapshot")
            return
        }
        #expect(recoveredDebtor.forcedSale == .init(shortfall: 10, eligiblePlacementIDs: eligible))

        let hostResult = try await recovery.recover(.init(
            protocolVersion: 1, rulesetVersion: catalog.catalog.rulesetVersion, roomID: room,
            playerID: hostID, reconnectToken: tokens[hostID]!, hostPlayerID: hostID,
            authenticatedRemotePlayerID: hostID, fromVersion: .init(rawValue: 2)
        ), from: archive, schemaVersion: SnapshotEnvelope.currentSchemaVersion, catalog: catalog)
        guard case .snapshot(let recoveredHost) = hostResult else {
            Issue.record("Expected observer fallback snapshot")
            return
        }
        #expect(recoveredHost.forcedSale == nil)

        let restored = try await recovery.restoreHost(
            archive: archive, expectedHostID: hostID, catalog: catalog
        )
        var resumed = try restored.gameState.makeHostEngine(
            roomID: room, reconnectTokens: tokens, protocolVersion: 1
        )
        let sale = resumed.submit(.init(
            protocolVersion: 1, rulesetVersion: catalog.catalog.rulesetVersion,
            roomID: room, senderID: debtorID, reconnectToken: tokens[debtorID]!,
            baseVersion: .init(rawValue: 4),
            payload: .forcedSale(.init(placementIDs: eligible))
        ), catalog: catalog)
        guard case .accepted = sale else {
            Issue.record("Recovered debtor must be able to continue the pending forced sale")
            return
        }
    }

    @Test func recoveryRejectsWrongTokenWrongHostUnknownSeatAndFutureVersion() async throws {
        let fixture = try await makeRecoveryFixture(windowVersions: [3, 4], persistedVersion: 4)
        let valid = RecoveryRequest(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: player, reconnectToken: .init(rawValue: "right-token"),
            hostPlayerID: .init(rawValue: "host"), authenticatedRemotePlayerID: .init(rawValue: "host"),
            fromVersion: .init(rawValue: 2)
        )
        await #expect(throws: RecoveryError.authenticationFailed) {
            try await fixture.coordinator.recover(
                valid.replacing(token: .init(rawValue: "wrong")),
                from: fixture.archive, schemaVersion: 2
            )
        }
        await #expect(throws: RecoveryError.wrongHost) {
            try await fixture.coordinator.recover(
                valid.replacing(authenticatedHost: .init(rawValue: "attacker")),
                from: fixture.archive, schemaVersion: 2
            )
        }
        await #expect(throws: RecoveryError.unknownSeat) {
            try await fixture.coordinator.recover(
                valid.replacing(playerID: .init(rawValue: "unknown")),
                from: fixture.archive, schemaVersion: 2
            )
        }
        await #expect(throws: RecoveryError.versionMismatch) {
            try await fixture.coordinator.recover(
                valid.replacing(fromVersion: .init(rawValue: 99)),
                from: fixture.archive, schemaVersion: 2
            )
        }
    }

    @Test func threeConsecutiveArchiveValidationFailuresClearOnlyRecoveryMaterialAndSuccessResetsTheCounter() async throws {
        let fixture = try await makeRecoveryFixture(windowVersions: [3, 4], persistedVersion: 4)
        let cleaner = RecordingRecoveryMaterialCleaner()
        let coordinator = RecoveryCoordinator(tokenStore: fixture.tokenStore, materialCleaner: cleaner)
        var broken = fixture.archive
        broken = broken.replacing(rulesetVersion: "tampered")
        let request = RecoveryRequest(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: player, reconnectToken: .init(rawValue: "right-token"),
            hostPlayerID: .init(rawValue: "host"), authenticatedRemotePlayerID: .init(rawValue: "host"),
            fromVersion: .init(rawValue: 2)
        )

        for attempt in 1...2 {
            await #expect(throws: RecoveryError.invalidMaterial) {
                try await coordinator.recover(request, from: broken, schemaVersion: 2)
            }
            #expect(await coordinator.consecutiveFailureCount(roomID: room, playerID: player) == attempt)
        }
        await #expect(throws: RecoveryError.returnToLobby("recovery-material-invalid")) {
            try await coordinator.recover(request, from: broken, schemaVersion: 2)
        }
        #expect(await coordinator.consecutiveFailureCount(roomID: room, playerID: player) == 3)
        for _ in 0..<5 {
            await #expect(throws: RecoveryError.returnToLobby("recovery-material-invalid")) {
                try await coordinator.recover(request, from: broken, schemaVersion: 2)
            }
            #expect(await coordinator.consecutiveFailureCount(roomID: room, playerID: player) == 3)
        }
        #expect(cleaner.clearedReferences == [.init(roomID: room, playerID: player)])
        #expect(try await fixture.tokenStore.load(roomID: room, playerID: player)?.reconnectToken.rawValue == "right-token")

        _ = try await coordinator.recover(request, from: fixture.archive, schemaVersion: 2)
        #expect(await coordinator.consecutiveFailureCount(roomID: room, playerID: player) == 0)
    }

    @Test func hostArchiveContainsOnlyTokenReferencesAndRelaunchRebindsTokensFromKeychain() async throws {
        let fixture = try await makeRecoveryFixture(windowVersions: [3, 4], persistedVersion: 4)
        let plaintext = try JSONEncoder.canonical.encode(fixture.archive)
        #expect(!plaintext.contains(Data("right-token".utf8)))
        #expect(!plaintext.contains(Data("host-token".utf8)))

        let restored = try await fixture.coordinator.restoreFixtureOnlyHost(
            archive: fixture.archive,
            expectedHostID: .init(rawValue: "host")
        )
        #expect(restored.state.authoritativeVersion == .init(rawValue: 4))
        #expect(restored.state.players.map(\.id) == [.init(rawValue: "host"), player])
        #expect(restored.state.players.first(where: { $0.id == player })?.reconnectToken.rawValue == "right-token")
        #expect(restored.eventWindows[player]?.count == 2)
    }

    @Test func acceptedHostActionPersistsConservativeRecoveryBeforeFanoutThenClearsIt() async throws {
        let pair = makePersistentCoordinatorPair()
        try await pair.host.createRoom()
        try await pair.guest.joinRoom()
        try await pair.host.setReady(true)
        try await pair.guest.setReady(true)
        try await eventually { await pair.host.readyPlayerIDs.count == 2 }
        try await pair.host.startGame()
        try await eventually { await pair.guest.snapshot != nil }
        let card = try #require(await pair.host.snapshot?.players.first(where: { $0.id.rawValue == "host" })?.hand?.first)
        try await pair.host.pass(discardCardID: card)

        let archives = await pair.persistence.savedArchives
        #expect(archives.map(\.commitSequence) == [1, 2])
        #expect(archives.allSatisfy { $0.authoritativeVersion == .init(rawValue: 1) })
        guard case let .host(precommit) = try #require(archives.first).payload,
              case let .host(delivered) = try #require(archives.last).payload else {
            Issue.record("Expected host archive")
            return
        }
        #expect(precommit.eventWindows[player]?.map(\.authoritativeVersion.rawValue) == [1])
        #expect(precommit.peersNeedingRecovery == [player])
        #expect(delivered.peersNeedingRecovery.isEmpty)
        #expect(await pair.observations.precommitVersionsSeenBeforeClientEvent == [.init(rawValue: 1)])
        #expect(await pair.observations.recoverySetsSeenBeforeClientEvent == [[player]])
        #expect(await pair.host.snapshot?.authoritativeVersion == .init(rawValue: 1))
    }

    @Test func acceptedBuildAndNetworkPersistCompleteCanonicalStateAtEachActionVersion() async throws {
        let catalog = try verifiedCatalog()
        let pair = makePersistentCoordinatorPair(catalog: catalog)
        try await pair.host.createRoom()
        try await pair.guest.joinRoom()
        try await pair.host.setReady(true)
        try await pair.guest.setReady(true)
        try await eventually { await pair.host.readyPlayerIDs.count == 2 }
        try await pair.host.startGame()
        try await eventually { await pair.guest.snapshot != nil }

        let hostID = GameCore.PlayerID(rawValue: "host")
        var setup = GameCore.SetupRules(seed: 1)
        let initial = try setup.makeGame(catalog: catalog, playerIDs: [hostID, player]).state
        let buildActor = try #require(initial.activePlayerID)
        let buildPlayer = try #require(initial.players.first(where: { $0.id == buildActor }))
        let tile = try #require(buildPlayer.industryStacks.first(where: {
            $0.industryDefinitionID == "brewery"
        })?.tiles.first)
        let choice = try #require(buildPlayer.hand.lazy.compactMap { card -> (GameCore.CardInstance, GameCore.BuildTarget)? in
            GameCore.BuildRules.legalBuildTargets(
                actorID: buildActor, cardID: card.id, tile: tile, state: initial, catalog: catalog
            ).first.map { (card, $0) }
        }.first)
        let iron = try #require(GameCore.GameRulesEngine.legalResourceSources(
            resource: .iron, consumerLocationID: choice.1.locationID,
            context: .standard, state: initial, catalog: catalog
        ).first)
        let buildCoordinator = buildActor == hostID ? pair.host : pair.guest
        try await buildCoordinator.submit(.build(.init(
            cardID: choice.0.id, locationID: choice.1.locationID,
            industryDefinitionID: "brewery", slotIndex: choice.1.slotIndex,
            resourceSources: [iron]
        )))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await buildCoordinator.lastIntentRejection == nil)
        #expect(await pair.host.persistenceError == nil)
        #expect(await pair.host.snapshot?.authoritativeVersion == .init(rawValue: 1))
        #expect(await pair.persistence.savedArchives.last?.authoritativeVersion == .init(rawValue: 1))
        guard case let .host(buildArchive) = try #require(await pair.persistence.savedArchives.last).payload else {
            Issue.record("Expected host build archive")
            return
        }
        #expect(buildArchive.gameState?.boardIndustryPlacements.count == 1)

        let networkActor = buildActor == hostID ? player : hostID
        let networkCoordinator = networkActor == hostID ? pair.host : pair.guest
        let networkCard = try #require(await networkCoordinator.snapshot?.players.first(where: { $0.id == networkActor })?.hand?.first)
        let route = try #require(catalog.catalog.board.routes.first(where: {
            $0.eras.contains(.canal) && $0.playerCounts.contains(2)
        }))
        try await networkCoordinator.submit(.network(.init(
            cardID: networkCard, routeIDs: [route.id], coalSources: [], beerSource: nil
        )))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await pair.host.snapshot?.authoritativeVersion == .init(rawValue: 2))
        #expect(await pair.persistence.savedArchives.last?.authoritativeVersion == .init(rawValue: 2))
        guard case let .host(networkArchive) = try #require(await pair.persistence.savedArchives.last).payload else {
            Issue.record("Expected host network archive")
            return
        }
        #expect(networkArchive.gameState?.placedLinks.map(\.routeID) == [route.id])
        #expect(networkArchive.gameState?.actionNumber == 2)
    }

    @Test func partialFanoutKeepsThePrecommitRecoveryEvidenceWithoutAdvancingProgressSequence() async throws {
        let pair = makePersistentCoordinatorPair()
        try await pair.host.createRoom(); try await pair.guest.joinRoom()
        try await pair.host.setReady(true); try await pair.guest.setReady(true)
        try await eventually { await pair.host.readyPlayerIDs.count == 2 }
        try await pair.host.startGame(); try await eventually { await pair.guest.snapshot != nil }
        await pair.failures.failSends(to: player)

        let card = try #require(await pair.host.snapshot?.players.first(where: { $0.id.rawValue == "host" })?.hand?.first)
        try await pair.host.pass(discardCardID: card)

        let archives = await pair.persistence.savedArchives
        #expect(archives.map(\.commitSequence) == [1])
        guard case let .host(precommit) = try #require(archives.last).payload else {
            Issue.record("Expected host archive")
            return
        }
        #expect(precommit.peersNeedingRecovery == [player])
        #expect(await pair.host.peersNeedingRecovery == [player])
        #expect(await pair.host.snapshot?.authoritativeVersion == .init(rawValue: 1))
    }

    @Test func firstSaveFailureLeavesHostAndGuestAtPreviousAuthorityWithoutFanout() async throws {
        let pair = makePersistentCoordinatorPair()
        try await pair.host.createRoom(); try await pair.guest.joinRoom()
        try await pair.host.setReady(true); try await pair.guest.setReady(true)
        try await eventually { await pair.host.readyPlayerIDs.count == 2 }
        try await pair.host.startGame(); try await eventually { await pair.guest.snapshot != nil }
        let initialHost = try #require(await pair.host.snapshot)
        let initialGuest = try #require(await pair.guest.snapshot)
        await pair.persistence.failSaves(true)

        let card = try #require(initialHost.players.first(where: { $0.id.rawValue == "host" })?.hand?.first)
        await #expect(throws: SessionCoordinator.Error.persistenceUnavailable) {
            try await pair.host.pass(discardCardID: card)
        }
        #expect(await pair.host.snapshot == initialHost)
        #expect(await pair.guest.snapshot == initialGuest)
        #expect(await pair.persistence.savedArchives.allSatisfy { $0.authoritativeVersion != .init(rawValue: 1) })
        #expect(await pair.observations.clientEventSendCount == 0)
        #expect(await pair.host.persistenceError == .saveFailed)

        let guestCard = try #require(initialGuest.players.first(where: { $0.id == player })?.hand?.first)
        try await pair.guest.pass(discardCardID: guestCard)
        try await eventually { await pair.guest.lastIntentRejection?.reasonCode == .persistenceUnavailable }
        #expect(await pair.host.snapshot == initialHost)
        #expect(await pair.guest.lastIntentRejection?.reasonCode == .persistenceUnavailable)
    }

    @Test func failedPrecommitRetryCommitsTheOriginalCandidateWithoutReplayingTheIntent() async throws {
        let hostID = GameCore.PlayerID(rawValue: "host")
        let pair = makePersistentCoordinatorPair()
        try await pair.host.createRoom(); try await pair.guest.joinRoom()
        try await pair.host.setReady(true); try await pair.guest.setReady(true)
        try await eventually { await pair.host.readyPlayerIDs.count == 2 }
        try await pair.host.startGame(); try await eventually { await pair.guest.snapshot != nil }
        let initialHost = try #require(await pair.host.snapshot)
        let initialGuest = try #require(await pair.guest.snapshot)
        let initialHostPlayer = try #require(initialHost.players.first(where: { $0.id == hostID }))
        let card = try #require(initialHostPlayer.hand?.first)
        await pair.persistence.failSave(number: 1)

        await #expect(throws: SessionCoordinator.Error.persistenceUnavailable) {
            try await pair.host.pass(discardCardID: card)
        }

        #expect(await pair.host.snapshot == initialHost)
        #expect(await pair.guest.snapshot == initialGuest)
        #expect(await pair.persistence.savedArchives.isEmpty)
        let failedCandidate = try #require(await pair.persistence.attemptedArchives.first)
        #expect(failedCandidate.authoritativeVersion == .init(rawValue: 1))
        #expect(failedCandidate.commitSequence == 1)

        try await pair.host.retryPersistence()

        let hostAfterRetry = try #require(await pair.host.snapshot)
        try #require(hostAfterRetry.authoritativeVersion == .init(rawValue: 1))
        try await eventually { await pair.guest.snapshot?.authoritativeVersion == .init(rawValue: 1) }
        let guestAfterRetry = try #require(await pair.guest.snapshot)
        let retryAttempts = await pair.persistence.attemptedArchives
        #expect(retryAttempts.count == 3)
        #expect(retryAttempts[0] == retryAttempts[1])
        #expect(await pair.persistence.savedArchives.map(\.commitSequence) == [1, 2])
        #expect(await pair.persistence.savedArchives.allSatisfy {
            $0.authoritativeVersion == .init(rawValue: 1)
        })
        #expect(hostAfterRetry.actionNumber == 1)
        #expect(guestAfterRetry.actionNumber == 1)
        #expect(hostAfterRetry.discardPile.filter { $0 == card }.count == 1)
        #expect(guestAfterRetry.discardPile.filter { $0 == card }.count == 1)
        let finalHostPlayer = try #require(hostAfterRetry.players.first(where: { $0.id == hostID }))
        #expect(finalHostPlayer.handCount == initialHostPlayer.handCount - 1)
        #expect(finalHostPlayer.hand?.contains(card) == false)
        #expect(guestAfterRetry.players.first(where: { $0.id == hostID })?.handCount == initialHostPlayer.handCount - 1)
        #expect(await pair.host.persistenceError == nil)
    }

    @Test func progressSaveFailureKeepsDurableAuthorityAndRecoveryEvidenceForRelaunch() async throws {
        let pair = makePersistentCoordinatorPair()
        try await pair.host.createRoom(); try await pair.guest.joinRoom()
        try await pair.host.setReady(true); try await pair.guest.setReady(true)
        try await eventually { await pair.host.readyPlayerIDs.count == 2 }
        try await pair.host.startGame(); try await eventually { await pair.guest.snapshot != nil }
        let guestAtVersionZero = try #require(await pair.guest.snapshot)
        await pair.persistence.failSave(number: 2)

        let card = try #require(await pair.host.snapshot?.players.first(where: { $0.id.rawValue == "host" })?.hand?.first)
        try await pair.host.pass(discardCardID: card)

        let durable = try #require(await pair.persistence.savedArchives.last)
        #expect(durable.authoritativeVersion == .init(rawValue: 1))
        #expect(durable.commitSequence == 1)
        guard case let .host(payload) = durable.payload else {
            Issue.record("Expected host archive")
            return
        }
        #expect(payload.peersNeedingRecovery == [player])
        #expect(payload.eventWindows[player]?.count == 1)
        #expect(await pair.host.snapshot?.authoritativeVersion == .init(rawValue: 1))
        #expect(await pair.host.persistenceError == .saveFailed)

        let restored = RestoredHostSession(
            state: .init(
                roomID: payload.authoritativeState.roomID,
                players: payload.authoritativeState.players.map {
                    .init(
                        id: $0.id,
                        reconnectToken: .init(rawValue: $0.id.rawValue == "host" ? "host-token" : "right-token"),
                        hand: $0.hand
                    )
                },
                activePlayerID: payload.authoritativeState.activePlayerID,
                turn: payload.authoritativeState.turn,
                actionNumber: payload.authoritativeState.actionNumber,
                authoritativeVersion: payload.authoritativeState.authoritativeVersion,
                discardPile: payload.authoritativeState.discardPile
            ),
            eventWindows: payload.eventWindows,
            peersNeedingRecovery: payload.peersNeedingRecovery,
            commitSequence: durable.commitSequence
        )
        let recoveryHub = LoopbackTransportHub()
        let relaunchedHost = try SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                playerID: .init(rawValue: "host"), reconnectToken: .init(rawValue: "host-token"),
                hostPlayerID: .init(rawValue: "host")
            ),
            restored: restored,
            transport: recoveryHub.makeTransport(peerID: .init(rawValue: "host")),
            rulesMode: .fixtureOnlyLegacy
        )
        let recoveringGuest = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                playerID: player, reconnectToken: .init(rawValue: "right-token"),
                hostPlayerID: .init(rawValue: "host")
            ),
            restoredGuest: .init(
                snapshot: guestAtVersionZero,
                eventWindow: [],
                tokenReference: .init(roomID: room, playerID: player),
                hostPlayerID: .init(rawValue: "host")
            ),
            transport: recoveryHub.makeTransport(peerID: player),
            rulesMode: .fixtureOnlyLegacy
        )
        try await relaunchedHost.createRoom()
        try await recoveringGuest.joinRoom()
        try await eventually { await recoveringGuest.snapshot?.authoritativeVersion == .init(rawValue: 1) }
        #expect(await relaunchedHost.snapshot?.authoritativeVersion == .init(rawValue: 1))
    }

    @Test func concurrentAcceptedActionWaitsForPriorFanoutAndDeliveryProgressToFinish() async throws {
        let hostID = GameCore.PlayerID(rawValue: "host")
        let secondGuestID = GameCore.PlayerID(rawValue: "guest-b")
        let hub = LoopbackTransportHub()
        let persistence = RecordingSessionArchivePersistence()
        let failures = PersistenceSendFailureControl()
        let observations = AtomicCommitObservation()
        let barrier = ClientEventSendBarrier(version: 1, peer: secondGuestID)
        let host = try SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                playerID: hostID, reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
            ),
            transport: PersistenceSelectiveFailingTransport(
                base: hub.makeTransport(peerID: hostID), failures: failures,
                persistence: persistence, observations: observations, barrier: barrier
            ),
            persistence: persistence,
            rulesMode: .fixtureOnlyLegacy
        )
        let firstGuest = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                playerID: player, reconnectToken: .init(rawValue: "right-token"), hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: player),
            rulesMode: .fixtureOnlyLegacy
        )
        let secondGuest = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                playerID: secondGuestID, reconnectToken: .init(rawValue: "second-token"), hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: secondGuestID),
            rulesMode: .fixtureOnlyLegacy
        )
        try await host.createRoom()
        try await firstGuest.joinRoom(); try await secondGuest.joinRoom()
        try await host.setReady(true); try await firstGuest.setReady(true); try await secondGuest.setReady(true)
        try await eventually { await host.readyPlayerIDs.count == 3 }
        try await host.startGame()
        try await eventually {
            let firstSnapshot = await firstGuest.snapshot
            let secondSnapshot = await secondGuest.snapshot
            return firstSnapshot != nil && secondSnapshot != nil
        }

        let hostCard = try #require(await host.snapshot?.players.first(where: { $0.id == hostID })?.hand?.first)
        let firstAction = Task { try await host.pass(discardCardID: hostCard) }
        await barrier.waitUntilBlocked()
        try await eventually { await firstGuest.snapshot?.authoritativeVersion == .init(rawValue: 1) }

        let firstGuestCard = try #require(await firstGuest.snapshot?.players.first(where: { $0.id == player })?.hand?.first)
        try await firstGuest.pass(discardCardID: firstGuestCard)
        try await Task.sleep(for: .milliseconds(100))

        #expect(await persistence.savedArchives.allSatisfy { $0.authoritativeVersion.rawValue <= 1 })
        #expect(await host.snapshot?.authoritativeVersion == .init(rawValue: 1))

        await barrier.release()
        try await firstAction.value
        try await eventually { await host.snapshot?.authoritativeVersion == .init(rawValue: 2) }
        try await eventually { await secondGuest.snapshot?.authoritativeVersion == .init(rawValue: 2) }
        #expect(await persistence.savedArchives.last?.authoritativeVersion == .init(rawValue: 2))
    }

    @Test func backgroundTriggerPersistsTheCurrentCommitWithoutAdvancingAuthority() async throws {
        let pair = makePersistentCoordinatorPair()
        try await pair.host.createRoom(); try await pair.guest.joinRoom()
        try await pair.host.setReady(true); try await pair.guest.setReady(true)
        try await eventually { await pair.host.readyPlayerIDs.count == 2 }
        try await pair.host.startGame(); try await eventually { await pair.host.snapshot != nil }
        let savesBefore = await pair.persistence.savedArchives.count

        try await pair.host.persistForBackground()
        try await pair.host.persistForBackground()

        #expect(await pair.persistence.savedArchives.count == savesBefore + 2)
        #expect(await pair.persistence.savedArchives.suffix(2).map(\.commitSequence) == [1, 2])
        #expect(await pair.persistence.savedArchives.last?.authoritativeVersion == .init(rawValue: 0))
    }

    @Test func guestRetryPersistenceSavesItsCurrentPrivateProjection() async throws {
        let hostID = GameCore.PlayerID(rawValue: "host")
        let hub = LoopbackTransportHub()
        let guestPersistence = RecordingSessionArchivePersistence()
        await guestPersistence.failSaves(true)
        let host = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                playerID: hostID, reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: hostID),
            rulesMode: .fixtureOnlyLegacy
        )
        let guest = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                playerID: player, reconnectToken: .init(rawValue: "right-token"), hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: player),
            persistence: guestPersistence,
            rulesMode: .fixtureOnlyLegacy
        )
        try await host.createRoom(); try await guest.joinRoom()
        try await host.setReady(true); try await guest.setReady(true)
        try await eventually { await host.readyPlayerIDs.count == 2 }
        try await host.startGame()
        try await eventually { await guest.persistenceError == .saveFailed }

        await guestPersistence.failSaves(false)
        try await guest.retryPersistence()

        #expect(await guest.persistenceError == nil)
        let archive = try #require(await guestPersistence.savedArchives.last)
        #expect(archive.role == .guest)
        #expect(archive.authoritativeVersion == .init(rawValue: 0))
    }

    @Test func actionPrecommitBackgroundAndRetryShareOnePersistenceGate() async throws {
        let hostID = GameCore.PlayerID(rawValue: "host")
        let hub = LoopbackTransportHub()
        let persistence = PausedSessionArchivePersistence()
        let host = try SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                playerID: hostID, reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: hostID), persistence: persistence,
            rulesMode: .fixtureOnlyLegacy
        )
        let guest = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                playerID: player, reconnectToken: .init(rawValue: "guest-token"), hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: player), rulesMode: .fixtureOnlyLegacy
        )
        try await host.createRoom(); try await guest.joinRoom()
        try await host.setReady(true); try await guest.setReady(true)
        try await eventually { await host.readyPlayerIDs.count == 2 }
        try await host.startGame(); try await eventually { await guest.snapshot != nil }
        let card = try #require(
            await host.snapshot?.players.first(where: { $0.id == hostID })?.hand?.first
        )

        let action = Task { try await host.pass(discardCardID: card) }
        await persistence.waitUntilFirstSaveIsPaused()
        let background = Task { try await host.persistForBackground() }
        let retry = Task { try await host.retryPersistence() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await persistence.attemptedSequences == [1])

        await persistence.releaseFirstSave()
        try await action.value
        try await background.value
        try await retry.value

        #expect(await persistence.savedSequences == [1, 2, 3, 4])
        #expect(await Set(persistence.savedSequences).count == 4)
        #expect(await host.persistenceError == nil)
    }

    @Test func guestPersistsOnlyItsOwnInitialSnapshotAndRecipientEventWindow() async throws {
        let room = self.room
        let hostID = GameCore.PlayerID(rawValue: "host")
        let hub = LoopbackTransportHub()
        let guestPersistence = RecordingSessionArchivePersistence()
        let host = SessionCoordinator(configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: hostID, reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
        ), transport: hub.makeTransport(peerID: hostID), rulesMode: .fixtureOnlyLegacy)
        let guest = SessionCoordinator(configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: player, reconnectToken: .init(rawValue: "right-token"), hostPlayerID: hostID
        ), transport: hub.makeTransport(peerID: player), persistence: guestPersistence,
           rulesMode: .fixtureOnlyLegacy)
        try await host.createRoom(); try await guest.joinRoom()
        try await host.setReady(true); try await guest.setReady(true)
        try await eventually { await host.readyPlayerIDs.count == 2 }
        try await host.startGame()
        try await eventually { await guestPersistence.savedArchives.last?.authoritativeVersion == .init(rawValue: 0) }
        let hostCard = try #require(await host.snapshot?.players.first(where: { $0.id == hostID })?.hand?.first)
        try await host.pass(discardCardID: hostCard)
        try await eventually { await guestPersistence.savedArchives.last?.authoritativeVersion == .init(rawValue: 1) }

        let archive = try #require(await guestPersistence.savedArchives.last)
        guard case let .guest(payload) = archive.payload else {
            Issue.record("Expected guest archive")
            return
        }
        #expect(payload.snapshot.recipient == player)
        #expect(payload.snapshot.players.allSatisfy { $0.id == player ? $0.hand != nil : $0.hand == nil })
        #expect(payload.eventWindow.map(\.authoritativeVersion.rawValue) == [1])
        #expect(payload.eventWindow.allSatisfy { $0.recipientID == player })
    }

    @Test func realTwoSeatScoutRedactsWildCardIDsFromOpponentFanoutAndGuestArchive() async throws {
        let catalog = try verifiedCatalog()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let hub = LoopbackTransportHub()
        let hostPersistence = RecordingSessionArchivePersistence()
        let guestPersistence = RecordingSessionArchivePersistence()
        let host = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: catalog.catalog.rulesetVersion, roomID: room,
                playerID: hostID, reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: hostID), persistence: hostPersistence,
            rulesMode: .verified(catalog)
        )
        let guest = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: catalog.catalog.rulesetVersion, roomID: room,
                playerID: player, reconnectToken: .init(rawValue: "right-token"), hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: player), persistence: guestPersistence,
            rulesMode: .verified(catalog)
        )
        try await host.createRoom(); try await guest.joinRoom()
        try await host.setReady(true); try await guest.setReady(true)
        try await eventually { await host.readyPlayerIDs.count == 2 }
        try await host.startGame()
        try await eventually { await guest.snapshot?.authoritativeVersion == .init(rawValue: 0) }

        var setup = GameCore.SetupRules(seed: 1)
        let initial = try setup.makeGame(catalog: catalog, playerIDs: [hostID, player]).state
        #expect(initial.activePlayerID == player)
        let guestPassCard = try #require(
            await guest.snapshot?.players.first(where: { $0.id == player })?.hand?.first
        )
        try await guest.pass(discardCardID: guestPassCard)
        try await eventually { await host.snapshot?.authoritativeVersion == .init(rawValue: 1) }
        #expect(await host.snapshot?.activePlayerID == hostID)
        let hostPlayer = try #require(initial.players.first(where: { $0.id == hostID }))
        let scoutCards = Array(hostPlayer.hand.prefix(3)).map(\.id)
        #expect(scoutCards.count == 3)
        let locationWildID = try #require(initial.wildLocationPool.last?.id)
        let industryWildID = try #require(initial.wildIndustryPool.last?.id)

        try await host.submit(.scout(.init(cardIDs: scoutCards)))
        try await eventually { await guest.snapshot?.authoritativeVersion == .init(rawValue: 2) }
        #expect(await host.lastIntentRejection == nil)
        #expect(await host.snapshot?.authoritativeVersion == .init(rawValue: 2))

        let hostArchive = try #require(await hostPersistence.savedArchives.last)
        guard case let .host(hostPayload) = hostArchive.payload,
              let actorEnvelope = hostPayload.eventWindows[hostID]?.last,
              let opponentEnvelope = hostPayload.eventWindows[player]?.last,
              case let .clientEvent(actorEvent) = actorEnvelope.payload,
              case let .clientEvent(opponentEvent) = opponentEnvelope.payload,
              case .scouted(.some) = actorEvent.event.payload,
              case .scouted(.none) = opponentEvent.event.payload
        else {
            Issue.record("Expected recipient-specific Scout event windows")
            return
        }
        let actorBytes = try JSONEncoder.canonical.encode(actorEnvelope)
        let opponentBytes = try JSONEncoder.canonical.encode(opponentEnvelope)
        #expect(actorBytes.contains(Data(locationWildID.utf8)))
        #expect(actorBytes.contains(Data(industryWildID.utf8)))
        #expect(!opponentBytes.contains(Data(locationWildID.utf8)))
        #expect(!opponentBytes.contains(Data(industryWildID.utf8)))

        let guestArchive = try #require(await guestPersistence.savedArchives.last)
        let guestArchiveBytes = try JSONEncoder.canonical.encode(guestArchive)
        #expect(!guestArchiveBytes.contains(Data(locationWildID.utf8)))
        #expect(!guestArchiveBytes.contains(Data(industryWildID.utf8)))
        guard case let .guest(guestPayload) = guestArchive.payload,
              case let .clientEvent(guestEvent) = try #require(guestPayload.eventWindow.last).payload,
              case .scouted(.none) = guestEvent.event.payload
        else {
            Issue.record("Expected redacted Scout event in guest archive")
            return
        }
    }

    @Test func restoredCoordinatorKeepsHostIdentitySeatsVersionAndRecoverySet() async throws {
        let fixture = try await makeRecoveryFixture(windowVersions: [3, 4], persistedVersion: 4)
        let restored = try await fixture.coordinator.restoreFixtureOnlyHost(
            archive: fixture.archive, expectedHostID: .init(rawValue: "host")
        )
        let hub = LoopbackTransportHub()
        let persistence = RecordingSessionArchivePersistence()
        let host = try SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                playerID: .init(rawValue: "host"), reconnectToken: .init(rawValue: "host-token"),
                hostPlayerID: .init(rawValue: "host")
            ),
            restored: restored,
            transport: hub.makeTransport(peerID: .init(rawValue: "host")),
            persistence: persistence,
            rulesMode: .fixtureOnlyLegacy
        )

        #expect(Set(await host.playerIDs) == [.init(rawValue: "host"), player])
        #expect(await host.snapshot?.authoritativeVersion == .init(rawValue: 4))
        #expect(await host.peersNeedingRecovery == restored.peersNeedingRecovery)
        try await host.createRoom()
        #expect(await host.snapshot?.authoritativeVersion == .init(rawValue: 4))
        try await host.persistForBackground()
        #expect(await persistence.savedArchives.last?.commitSequence == restored.commitSequence + 1)
    }

    @MainActor
    @Test func viewStoreFailsClosedOnPersistenceErrorAndLifecycleBackgroundCanRetry() async throws {
        let pair = makePersistentCoordinatorPair()
        let store = SessionViewStore(
            coordinator: pair.host, role: .host, roomID: room,
            playerID: .init(rawValue: "host"), hostPlayerID: .init(rawValue: "host")
        )
        await store.connect(); try await pair.guest.joinRoom()
        await store.setReady(true); try await pair.guest.setReady(true)
        try await eventuallyMainActor { store.readyPlayerIDs.count == 2 }
        await store.startGame(); try await eventuallyMainActor { store.snapshot != nil }
        await pair.persistence.failSaves(true)
        store.selectCard("card-0-a")

        await store.submitPass()
        try await eventuallyMainActor { store.syncStatus == .failed }
        #expect(!store.canSubmitPass)
        #expect(store.errorMessage == "无法安全保存对局，已暂停新行动。请重试恢复。")
        #expect(store.errorMessage?.contains("token") == false)

        await pair.persistence.failSaves(false)
        await store.handleScenePhase(.background)
        try await eventuallyMainActor { store.syncStatus == .synchronized }
        #expect(store.errorMessage == nil)
    }

    @MainActor
    @Test func viewStoreRetryPersistsCurrentAuthorityWithoutReplayingTheAction() async throws {
        let hostID = GameCore.PlayerID(rawValue: "host")
        let pair = makePersistentCoordinatorPair()
        let store = SessionViewStore(
            coordinator: pair.host, role: .host, roomID: room,
            playerID: hostID, hostPlayerID: hostID
        )
        await store.connect(); try await pair.guest.joinRoom()
        await store.setReady(true); try await pair.guest.setReady(true)
        try await eventuallyMainActor { store.readyPlayerIDs.count == 2 }
        await store.startGame(); try await eventuallyMainActor { store.snapshot != nil }
        await pair.persistence.failSave(number: 2)
        store.selectCard(try #require(store.hand.first))

        await store.submitPass()

        try await eventuallyMainActor {
            store.version == .init(rawValue: 1) && store.hasPersistenceFailure
        }
        #expect(await pair.host.snapshot?.authoritativeVersion == .init(rawValue: 1))
        #expect(store.syncStatus == .failed)
        #expect(store.canRetryPersistence)
        #expect(store.errorMessage == "无法安全保存对局，已暂停新行动。请重试恢复。")

        await store.retryPersistence()

        try await eventuallyMainActor {
            store.syncStatus == .synchronized && !store.hasPersistenceFailure
        }
        #expect(store.errorMessage == nil)
        #expect(store.version == .init(rawValue: 1))
        #expect(await pair.host.snapshot?.authoritativeVersion == .init(rawValue: 1))
    }

    @MainActor
    @Test func viewStoreFailedRetryRemainsRetryable() async throws {
        let hostID = GameCore.PlayerID(rawValue: "host")
        let pair = makePersistentCoordinatorPair()
        let store = SessionViewStore(
            coordinator: pair.host, role: .host, roomID: room,
            playerID: hostID, hostPlayerID: hostID
        )
        await store.connect(); try await pair.guest.joinRoom()
        await store.setReady(true); try await pair.guest.setReady(true)
        try await eventuallyMainActor { store.readyPlayerIDs.count == 2 }
        await store.startGame(); try await eventuallyMainActor { store.snapshot != nil }
        await pair.persistence.failSave(number: 2)
        await pair.persistence.failSave(number: 3)
        store.selectCard(try #require(store.hand.first))
        await store.submitPass()
        try await eventuallyMainActor { store.hasPersistenceFailure }

        await store.retryPersistence()

        #expect(store.hasPersistenceFailure)
        #expect(store.canRetryPersistence)
        #expect(!store.isRetryingPersistence)
        #expect(store.syncStatus == .failed)
        #expect(store.errorMessage == "无法安全保存对局，已暂停新行动。请重试恢复。")
    }

    @MainActor
    @Test func viewStoreIgnoresDuplicateRetryWhileSaving() async throws {
        let hostID = GameCore.PlayerID(rawValue: "host")
        let pair = makePersistentCoordinatorPair()
        let store = SessionViewStore(
            coordinator: pair.host, role: .host, roomID: room,
            playerID: hostID, hostPlayerID: hostID
        )
        await store.connect(); try await pair.guest.joinRoom()
        await store.setReady(true); try await pair.guest.setReady(true)
        try await eventuallyMainActor { store.readyPlayerIDs.count == 2 }
        await store.startGame(); try await eventuallyMainActor { store.snapshot != nil }
        await pair.persistence.failSave(number: 2)
        store.selectCard(try #require(store.hand.first))
        await store.submitPass()
        try await eventuallyMainActor { store.hasPersistenceFailure }
        let attemptsBeforeRetry = await pair.persistence.saveAttemptCount
        await pair.persistence.delaySaves(.milliseconds(150))

        let firstRetry = Task { await store.retryPersistence() }
        try await eventuallyMainActor { store.isRetryingPersistence }
        #expect(!store.canRetryPersistence)

        await store.retryPersistence()

        #expect(store.isRetryingPersistence)
        #expect(!store.canRetryPersistence)
        await firstRetry.value
        try await eventuallyMainActor {
            !store.hasPersistenceFailure && !store.isRetryingPersistence
        }
        #expect(await pair.persistence.saveAttemptCount == attemptsBeforeRetry + 1)
        #expect(store.syncStatus == .synchronized)
    }

    @MainActor
    @Test func activeAndInactiveLifecyclePhasesDoNotWriteSnapshots() async throws {
        let pair = makePersistentCoordinatorPair()
        let store = SessionViewStore(coordinator: pair.host, role: .host, roomID: room,
                                     playerID: .init(rawValue: "host"))
        await store.connect(); try await pair.guest.joinRoom()
        await store.setReady(true); try await pair.guest.setReady(true)
        try await eventuallyMainActor { store.readyPlayerIDs.count == 2 }
        await store.startGame(); try await eventuallyMainActor { store.snapshot != nil }
        let before = await pair.persistence.savedArchives.count

        await store.handleScenePhase(.active)
        await store.handleScenePhase(.inactive)

        #expect(await pair.persistence.savedArchives.count == before)
    }

    @MainActor
    @Test func guestBackgroundPersistsItsRestoredPrivateProjectionWithoutHostAuthority() async throws {
        let persistence = RecordingSessionArchivePersistence()
        let snapshot = makeSnapshot(recipient: player, opponentHand: nil, version: 2)
        let coordinator = try SessionCoordinator(
            configuration: .init(
                protocolVersion: 1,
                rulesetVersion: "rules-v1",
                roomID: room,
                playerID: player,
                reconnectToken: .init(rawValue: "right-token"),
                hostPlayerID: .init(rawValue: "host")
            ),
            restoredGuest: .init(
                snapshot: snapshot,
                eventWindow: [],
                tokenReference: .init(roomID: room, playerID: player),
                hostPlayerID: .init(rawValue: "host")
            ),
            transport: LoopbackTransportHub().makeTransport(peerID: player),
            persistence: persistence,
            rulesMode: .fixtureOnlyLegacy
        )
        let store = SessionViewStore(
            coordinator: coordinator,
            role: .guest,
            roomID: room,
            playerID: player
        )

        await store.handleScenePhase(.background)

        let saved = await persistence.savedArchives
        #expect(saved.count == 1)
        #expect(saved.first?.role == .guest)
        #expect(store.syncStatus != .failed)
    }

    @MainActor
    @Test func restoredGuestCannotSubmitAnIntentBeforeReauthenticationCompletes() async throws {
        let snapshot = makeSnapshot(recipient: player, opponentHand: nil, version: 2)
        let coordinator = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room, playerID: player,
                reconnectToken: .init(rawValue: "right-token"), hostPlayerID: .init(rawValue: "host")
            ),
            restoredGuest: .init(
                snapshot: snapshot, eventWindow: [],
                tokenReference: .init(roomID: room, playerID: player),
                hostPlayerID: .init(rawValue: "host")
            ),
            transport: LoopbackTransportHub().makeTransport(peerID: player),
            rulesMode: .fixtureOnlyLegacy
        )
        let store = SessionViewStore(
            coordinator: coordinator, role: .guest, roomID: room, playerID: player
        )
        try await eventuallyMainActor { store.snapshot != nil }
        store.selectCard("card-private")

        #expect(!store.canSubmitPass)
    }

    @MainActor
    @Test func guestStaysRecoveringThroughIntermediateEventUntilHostTargetVersionArrives() async throws {
        let hostID = GameCore.PlayerID(rawValue: "host")
        let fixture = try await makeRecoveryFixture(windowVersions: [3, 4], persistedVersion: 4)
        let restored = try await fixture.coordinator.restoreFixtureOnlyHost(
            archive: fixture.archive, expectedHostID: hostID
        )
        let hub = LoopbackTransportHub()
        let gate = RecoveryDeliveryGate(pausedVersion: 4)
        let host = try SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room, playerID: hostID,
                reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
            ),
            restored: restored,
            transport: GatedRecoveryTransport(base: hub.makeTransport(peerID: hostID), gate: gate),
            rulesMode: .fixtureOnlyLegacy
        )
        let guest = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room, playerID: player,
                reconnectToken: .init(rawValue: "right-token"), hostPlayerID: hostID
            ),
            restoredGuest: .init(
                snapshot: makeSnapshot(recipient: player, opponentHand: nil, version: 2),
                eventWindow: [], tokenReference: .init(roomID: room, playerID: player),
                hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: player),
            rulesMode: .fixtureOnlyLegacy
        )
        let store = SessionViewStore(
            coordinator: guest, role: .guest, roomID: room, playerID: player, hostPlayerID: hostID
        )

        try await host.createRoom()
        #expect(await store.connect() == nil)
        try await eventuallyMainActor { store.version == .init(rawValue: 3) }
        store.selectCard("card-private")
        #expect(store.syncStatus == .recovering)
        #expect(!store.canSubmitPass)

        await gate.release()
        try await eventuallyMainActor {
            store.version == .init(rawValue: 4) && store.syncStatus == .synchronized
        }
        #expect(store.canSubmitPass)
    }

    @Test func threeAuthenticatedInvalidGuestRecoveryMessagesClearOnlyLocalMaterialAndFailClosed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x5A, count: 32))
        let store = SnapshotStore(directory: directory, keyProvider: key)
        let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
        let credential = RoomTokenCredential(
            roomID: room, playerID: player, reconnectToken: .init(rawValue: "right-token")
        )
        try await tokenStore.save(credential)
        let archive = makeGuestArchive(sequence: 2)
        try await store.save(archive)
        guard case let .guest(restoredGuest) = archive.payload else { return }
        let tracker = SessionRecoveryFailureTracker()
        let handler = GuestRecoveryFailureHandler(
            tracker: tracker, snapshotStore: store,
            reference: .init(roomID: room, playerID: player)
        )
        let hub = LoopbackTransportHub()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let hostTransport = hub.makeTransport(peerID: hostID)
        let attackerID = GameCore.PlayerID(rawValue: "attacker")
        let attackerTransport = hub.makeTransport(peerID: attackerID)
        let guest = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                playerID: player, reconnectToken: credential.reconnectToken, hostPlayerID: hostID
            ),
            restoredGuest: restoredGuest,
            restoredCommitSequence: archive.commitSequence,
            transport: hub.makeTransport(peerID: player),
            persistence: store,
            guestRecoveryFailureHandler: handler,
            rulesMode: .fixtureOnlyLegacy
        )
        let host = SessionCoordinator(configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: hostID, reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
        ), transport: hostTransport, rulesMode: .fixtureOnlyLegacy)
        try await host.createRoom(); try await guest.joinRoom()
        try await attackerTransport.connect(to: player)
        let outerUnauthenticated = SessionProtocol.SessionEnvelope(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            messageID: .init(rawValue: "outer-attacker"), senderID: hostID,
            recipientID: .init(rawValue: "wrong-recipient"), authoritativeVersion: .init(rawValue: 3),
            payload: .viewSnapshot(makeSnapshot(recipient: player, opponentHand: nil, version: 3))
        )
        try await attackerTransport.send(JSONEncoder.canonical.encode(outerUnauthenticated), to: player)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await tracker.failureCount(for: .init(roomID: room, playerID: player)) == 0)

        let checksumValue = makeSnapshot(recipient: player, opponentHand: nil, version: 3)
        let badChecksum = GameCore.ViewSnapshot(
            roomID: checksumValue.roomID, recipient: checksumValue.recipient, players: checksumValue.players,
            activePlayerID: checksumValue.activePlayerID, turn: checksumValue.turn,
            actionNumber: checksumValue.actionNumber, authoritativeVersion: checksumValue.authoritativeVersion,
            discardPile: checksumValue.discardPile, checksum: "bad-checksum"
        )
        let mismatchedVersion = makeSnapshot(recipient: player, opponentHand: nil, version: 3)
        let actorBase = makeRecoveryEnvelope(version: 3, persistedState: .init(
            roomID: room, players: [], activePlayerID: player, turn: 4, actionNumber: 3,
            authoritativeVersion: .init(rawValue: 3), discardPile: []
        ))
        guard case let .clientEvent(actorEvent) = actorBase.payload else { return }
        let unknownActor = GameCore.AuthoritativeGameEvent(
            roomID: actorEvent.event.roomID, actor: .init(rawValue: "unknown-actor"),
            previousVersion: actorEvent.event.previousVersion, version: actorEvent.event.version,
            actionNumber: actorEvent.event.actionNumber, payload: actorEvent.event.payload
        )
        let invalidEnvelopes: [SessionProtocol.SessionEnvelope] = [
            .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                messageID: .init(rawValue: "bad-checksum"), senderID: hostID, recipientID: player,
                authoritativeVersion: .init(rawValue: 3), payload: .viewSnapshot(badChecksum)
            ),
            .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                messageID: .init(rawValue: "bad-version"), senderID: hostID, recipientID: player,
                authoritativeVersion: .init(rawValue: 4), payload: .viewSnapshot(mismatchedVersion)
            ),
            .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                messageID: .init(rawValue: "bad-actor"), senderID: hostID, recipientID: player,
                authoritativeVersion: .init(rawValue: 3),
                payload: .clientEvent(.init(event: unknownActor, snapshot: actorEvent.snapshot))
            ),
        ]
        for envelope in invalidEnvelopes {
            try await hostTransport.send(JSONEncoder.canonical.encode(envelope), to: player)
        }
        try await eventually { await guest.recoveryError == .returnToLobby("recovery-material-invalid") }
        #expect(!FileManager.default.fileExists(atPath: store.committedFileURL.path))
        #expect(try await tokenStore.load(roomID: room, playerID: player) == credential)
        #expect(await guest.pauseReason == .stateRecovery)
    }

    @Test func productionGuestRecoveryFailureHandlerResetsAfterSuccess() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(
            directory: directory,
            keyProvider: FixedSnapshotKeyProvider(key: Data(repeating: 0x5B, count: 32))
        )
        let tracker = SessionRecoveryFailureTracker()
        let reference = RoomTokenReference(roomID: room, playerID: player)
        let handler = GuestRecoveryFailureHandler(tracker: tracker, snapshotStore: store, reference: reference)

        _ = try await handler.recordInvalidAuthenticatedMessage()
        #expect(await tracker.failureCount(for: reference) == 1)
        await handler.recoverySucceeded()
        #expect(await tracker.failureCount(for: reference) == 0)
    }

    @Test func duplicateInvalidRecoveryIDCountsOnceAndDoesNotBlockLaterValidMessageWithSameID() async throws {
        let tracker = SessionRecoveryFailureTracker()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotStore = SnapshotStore(
            directory: directory,
            keyProvider: FixedSnapshotKeyProvider(key: Data(repeating: 0x5C, count: 32))
        )
        let reference = RoomTokenReference(roomID: room, playerID: player)
        let hub = LoopbackTransportHub()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let hostTransport = hub.makeTransport(peerID: hostID)
        let guest = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                playerID: player, reconnectToken: .init(rawValue: "right-token"), hostPlayerID: hostID
            ),
            restoredGuest: .init(
                snapshot: makeSnapshot(recipient: player, opponentHand: nil, version: 2),
                eventWindow: [], tokenReference: reference, hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: player),
            guestRecoveryFailureHandler: GuestRecoveryFailureHandler(
                tracker: tracker, snapshotStore: snapshotStore, reference: reference
            ),
            rulesMode: .fixtureOnlyLegacy
        )
        let host = SessionCoordinator(configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: hostID, reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
        ), transport: hostTransport, rulesMode: .fixtureOnlyLegacy)
        try await host.createRoom(); try await guest.joinRoom()
        let messageID = SessionProtocol.MessageID(rawValue: "reused-after-invalid")
        let valid = makeSnapshot(recipient: player, opponentHand: nil, version: 3)
        let invalid = GameCore.ViewSnapshot(
            roomID: valid.roomID, recipient: valid.recipient, players: valid.players,
            activePlayerID: valid.activePlayerID, turn: valid.turn, actionNumber: valid.actionNumber,
            authoritativeVersion: valid.authoritativeVersion, discardPile: valid.discardPile,
            checksum: "bad"
        )
        let badEnvelope = SessionProtocol.SessionEnvelope(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            messageID: messageID, senderID: hostID, recipientID: player,
            authoritativeVersion: .init(rawValue: 3), payload: .viewSnapshot(invalid)
        )
        for _ in 0..<3 {
            try await hostTransport.send(JSONEncoder.canonical.encode(badEnvelope), to: player)
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await tracker.failureCount(for: reference) == 1)

        let validEnvelope = SessionProtocol.SessionEnvelope(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            messageID: messageID, senderID: hostID, recipientID: player,
            authoritativeVersion: .init(rawValue: 3), payload: .viewSnapshot(valid)
        )
        try await hostTransport.send(JSONEncoder.canonical.encode(validEnvelope), to: player)
        try await eventually { await guest.snapshot?.authoritativeVersion == .init(rawValue: 3) }
    }

    @Test func invalidRecoveryReplayCacheIsBoundedAndEvictsOldestIDs() {
        let hostID = GameCore.PlayerID(rawValue: "host")
        var cache = InvalidRecoveryReplayCache(capacity: 128)
        for index in 0..<129 {
            let inserted = cache.insert(.init(rawValue: "invalid-\(index)"), authenticatedHostID: hostID)
            #expect(inserted)
        }
        #expect(cache.count == 128)
        let reinsertedOldest = cache.insert(.init(rawValue: "invalid-0"), authenticatedHostID: hostID)
        let duplicateNewest = cache.insert(.init(rawValue: "invalid-128"), authenticatedHostID: hostID)
        #expect(reinsertedOldest)
        #expect(!duplicateNewest)
    }

    @Test func fallbackSnapshotClearsStaleGuestEventWindowBeforePersisting() async throws {
        let persistence = RecordingSessionArchivePersistence()
        let hub = LoopbackTransportHub()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let hostTransport = hub.makeTransport(peerID: hostID)
        let stale = makeRecoveryEnvelope(version: 2, persistedState: .init(
            roomID: room, players: [], activePlayerID: player, turn: 3, actionNumber: 2,
            authoritativeVersion: .init(rawValue: 2), discardPile: []
        ))
        let guest = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                playerID: player, reconnectToken: .init(rawValue: "right-token"), hostPlayerID: hostID
            ),
            restoredGuest: .init(
                snapshot: makeSnapshot(recipient: player, opponentHand: nil, version: 2),
                eventWindow: [stale], tokenReference: .init(roomID: room, playerID: player),
                hostPlayerID: hostID
            ),
            restoredCommitSequence: 4,
            transport: hub.makeTransport(peerID: player),
            persistence: persistence,
            rulesMode: .fixtureOnlyLegacy
        )
        let host = SessionCoordinator(configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: hostID, reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
        ), transport: hostTransport, rulesMode: .fixtureOnlyLegacy)
        try await host.createRoom(); try await guest.joinRoom()
        let fallback = makeSnapshot(recipient: player, opponentHand: nil, version: 4)
        let envelope = SessionProtocol.SessionEnvelope(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            messageID: .init(rawValue: "fallback-4"), senderID: hostID, recipientID: player,
            authoritativeVersion: .init(rawValue: 4), payload: .viewSnapshot(fallback)
        )
        try await hostTransport.send(JSONEncoder.canonical.encode(envelope), to: player)
        try await eventually { await persistence.savedArchives.last?.authoritativeVersion == .init(rawValue: 4) }
        guard case let .guest(payload) = try #require(await persistence.savedArchives.last).payload else { return }
        #expect(payload.eventWindow.isEmpty)
    }

    @Test func envelopeValidatorAllowsAuthenticatedCreateRoomToAdvertiseRecoveryTarget() throws {
        let hostID = GameCore.PlayerID(rawValue: "host")
        let envelope = SessionProtocol.SessionEnvelope(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            messageID: .init(rawValue: "create-target"), senderID: hostID, recipientID: player,
            authoritativeVersion: .init(rawValue: 4), payload: .createRoom
        )
        let context = SessionProtocol.SessionContext(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            localPlayerID: player, authenticatedRemotePlayerID: hostID, hostPlayerID: hostID,
            roomPlayerIDs: [hostID, player], authoritativeVersion: .init(rawValue: 2), actionNumber: 2,
            reconnectTokens: [hostID: .init(rawValue: "transport-authenticated-host")]
        )

        #expect(try SessionProtocol.EnvelopeValidator().validate(envelope, against: context) == .createRoom)
    }

    @MainActor
    @Test func guestPausesWithoutElectingItselfWhenTheHostDisconnects() async throws {
        let room = self.room
        let hostID = GameCore.PlayerID(rawValue: "host")
        let hub = LoopbackTransportHub()
        let host = SessionCoordinator(configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: hostID, reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
        ), transport: hub.makeTransport(peerID: hostID), rulesMode: .fixtureOnlyLegacy)
        let guest = SessionCoordinator(configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: player, reconnectToken: .init(rawValue: "right-token"), hostPlayerID: hostID
        ), transport: hub.makeTransport(peerID: player), rulesMode: .fixtureOnlyLegacy)
        let store = SessionViewStore(coordinator: guest, role: .guest, roomID: room,
                                     playerID: player, hostPlayerID: hostID)
        try await host.createRoom(); await store.connect()
        try await host.setReady(true); await store.setReady(true)
        try await eventuallyMainActor { store.readyPlayerIDs.count == 2 }
        try await host.startGame(); try await eventuallyMainActor { store.snapshot != nil }

        await host.disconnect()

        try await eventuallyMainActor { store.syncStatus == .recovering }
        #expect(store.errorMessage == "正在等待原房主恢复连接，期间无法提交新行动。")
        #expect(!store.isHost)
        #expect(!store.canSubmitPass)
    }

    @Test func productionFactoryScopesPathsAndReusesExistingKeychainCredential() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = InMemorySecureItemAdapter()
        let tokenStore = RoomTokenStore(adapter: adapter)
        let factory = SessionPersistenceFactory(
            baseDirectory: directory,
            tokenStore: tokenStore,
            keyProvider: FixedSnapshotKeyProvider(key: Data(repeating: 0x66, count: 32))
        )
        let configuration = SessionCoordinator.Configuration(
            protocolVersion: 1, rulesetVersion: "rules-v1",
            roomID: .init(rawValue: "../../private room"), playerID: player,
            reconnectToken: .init(rawValue: "first-token"), hostPlayerID: .init(rawValue: "host")
        )
        _ = try await factory.makeCoordinator(
            configuration: configuration, role: .guest,
            transport: LoopbackTransportHub().makeTransport(peerID: player),
            rulesMode: .fixtureOnlyLegacy
        )
        let changedProposal = SessionCoordinator.Configuration(
            protocolVersion: 1, rulesetVersion: "rules-v1",
            roomID: configuration.roomID, playerID: player,
            reconnectToken: .init(rawValue: "second-token"), hostPlayerID: .init(rawValue: "host")
        )
        _ = try await factory.makeCoordinator(
            configuration: changedProposal, role: .guest,
            transport: LoopbackTransportHub().makeTransport(peerID: player),
            rulesMode: .fixtureOnlyLegacy
        )

        #expect(try await tokenStore.load(roomID: configuration.roomID, playerID: player)?.reconnectToken.rawValue == "first-token")
        let scoped = factory.directory(roomID: configuration.roomID, playerID: player)
        #expect(scoped.path.hasPrefix(directory.path))
        #expect(!scoped.path.contains(".."))
        #expect(!scoped.lastPathComponent.contains("private room"))
    }

    @Test func productionFactoryRestoresHostArchiveAndHostPersistsJoinedSeatToken() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = InMemorySecureItemAdapter()
        let tokenStore = RoomTokenStore(adapter: adapter)
        let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x77, count: 32))
        let factory = SessionPersistenceFactory(baseDirectory: directory, tokenStore: tokenStore, keyProvider: key)
        let fixture = try await makeRecoveryFixture(windowVersions: [3, 4], persistedVersion: 4)
        guard case let .host(hostPayload) = fixture.archive.payload else { return }
        for player in hostPayload.authoritativeState.players {
            let token = player.id.rawValue == "host" ? "host-token" : "right-token"
            try await tokenStore.save(.init(roomID: room, playerID: player.id, reconnectToken: .init(rawValue: token)))
        }
        let snapshotStore = SnapshotStore(directory: factory.directory(roomID: room, playerID: .init(rawValue: "host")), keyProvider: key)
        try await snapshotStore.save(fixture.archive)
        let hub = LoopbackTransportHub()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let restoredHost = try await factory.makeCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room, playerID: hostID,
                reconnectToken: .init(rawValue: "new-proposal"), hostPlayerID: hostID
            ), role: .host, transport: hub.makeTransport(peerID: hostID),
            rulesMode: .fixtureOnlyLegacy
        )
        #expect(await restoredHost.snapshot?.authoritativeVersion == .init(rawValue: 4))

        let newRoom = GameCore.RoomID(rawValue: "NEW-ROOM")
        let host = try await factory.makeCoordinator(configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: newRoom, playerID: hostID,
            reconnectToken: .init(rawValue: "host-new"), hostPlayerID: hostID
        ), role: .host, transport: hub.makeTransport(peerID: hostID),
           rulesMode: .fixtureOnlyLegacy)
        let guest = SessionCoordinator(configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: newRoom, playerID: player,
            reconnectToken: .init(rawValue: "guest-new"), hostPlayerID: hostID
        ), transport: hub.makeTransport(peerID: player), rulesMode: .fixtureOnlyLegacy)
        try await host.createRoom(); try await guest.joinRoom()
        try await eventually {
            (try? await tokenStore.load(roomID: newRoom, playerID: self.player)?.reconnectToken.rawValue) == "guest-new"
        }
    }

    @Test func nearbyRuntimeFactoryReusesDurableSecureItemsAcrossInstances() async throws {
        let roomID = GameCore.RoomID(rawValue: "RUNTIME-\(UUID().uuidString)")
        let hostID = GameCore.PlayerID(rawValue: "host")
        let guestID = GameCore.PlayerID(rawValue: "guest-runtime")
        let firstFactory = SessionPersistenceFactory.nearbyRuntime
        let hostDirectory = firstFactory.directory(roomID: roomID, playerID: hostID)
        let guestDirectory = firstFactory.directory(roomID: roomID, playerID: guestID)
        defer {
            try? FileManager.default.removeItem(at: hostDirectory)
            try? FileManager.default.removeItem(at: guestDirectory)
        }
        func deleteRuntimeTokens() async {
            try? await firstFactory.tokenStore.delete(roomID: roomID, playerID: hostID)
            try? await firstFactory.tokenStore.delete(roomID: roomID, playerID: guestID)
        }

        do {
            let hub = LoopbackTransportHub()
            let firstHost = try await firstFactory.makeCoordinator(
                configuration: .init(
                    protocolVersion: 1, rulesetVersion: "rules-v1", roomID: roomID, playerID: hostID,
                    reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
                ),
                role: .host,
                transport: hub.makeTransport(peerID: hostID),
                rulesMode: .fixtureOnlyLegacy
            )
            let guest = SessionCoordinator(
                configuration: .init(
                    protocolVersion: 1, rulesetVersion: "rules-v1", roomID: roomID, playerID: guestID,
                    reconnectToken: .init(rawValue: "guest-token"), hostPlayerID: hostID
                ),
                transport: hub.makeTransport(peerID: guestID),
                rulesMode: .fixtureOnlyLegacy
            )

            try await firstHost.createRoom()
            try await guest.joinRoom()
            try await firstHost.setReady(true)
            try await guest.setReady(true)
            try await eventually { await firstHost.readyPlayerIDs.count == 2 }
            try await firstHost.startGame()
            let firstSnapshot = try #require(await firstHost.snapshot)
            let hostCard = try #require(firstSnapshot.players.first(where: { $0.id == hostID })?.hand?.first)
            try await firstHost.pass(discardCardID: hostCard)
            try await eventually { await firstHost.snapshot?.authoritativeVersion == .init(rawValue: 1) }

            let secondFactory = SessionPersistenceFactory.nearbyRuntime
            let restoredHost = try await secondFactory.makeCoordinator(
                configuration: .init(
                    protocolVersion: 1, rulesetVersion: "rules-v1", roomID: roomID, playerID: hostID,
                    reconnectToken: .init(rawValue: "ignored-new-token"), hostPlayerID: hostID
                ),
                role: .host,
                transport: LoopbackTransportHub().makeTransport(peerID: hostID),
                rulesMode: .fixtureOnlyLegacy
            )

            #expect(await restoredHost.snapshot?.authoritativeVersion == .init(rawValue: 1))
            #expect(try await secondFactory.tokenStore.load(roomID: roomID, playerID: hostID)?.reconnectToken.rawValue == "host-token")
        } catch {
            await deleteRuntimeTokens()
            throw error
        }
        await deleteRuntimeTokens()
    }

    @Test func productionFactoryClearsOnlyEncryptedRecoveryMaterialAfterThreeInvalidLoads() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = InMemorySecureItemAdapter()
        let tokenStore = RoomTokenStore(adapter: adapter)
        let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x65, count: 32))
        let factory = SessionPersistenceFactory(baseDirectory: directory, tokenStore: tokenStore, keyProvider: key)
        let hostID = GameCore.PlayerID(rawValue: "host")
        let credential = RoomTokenCredential(
            roomID: room, playerID: hostID, reconnectToken: .init(rawValue: "host-token")
        )
        try await tokenStore.save(credential)
        let store = SnapshotStore(directory: factory.directory(roomID: room, playerID: hostID), keyProvider: key)
        let fixture = try await makeRecoveryFixture(windowVersions: [1], persistedVersion: 1)
        try await store.save(fixture.archive)
        var bytes = try Data(contentsOf: store.committedFileURL)
        bytes[bytes.startIndex] ^= 0xff
        try bytes.write(to: store.committedFileURL)
        let configuration = SessionCoordinator.Configuration(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room, playerID: hostID,
            reconnectToken: .init(rawValue: "ignored"), hostPlayerID: hostID
        )

        for attempt in 1...3 {
            do {
                _ = try await factory.makeCoordinator(
                    configuration: configuration, role: .host,
                    transport: LoopbackTransportHub().makeTransport(peerID: hostID),
                    rulesMode: .fixtureOnlyLegacy
                )
                Issue.record("invalid recovery material unexpectedly loaded")
            } catch let error as RecoveryError where attempt == 3 {
                #expect(error == .returnToLobby("recovery-material-invalid"))
            } catch is SnapshotStoreError {
                #expect(attempt < 3)
            }
        }

        #expect(!FileManager.default.fileExists(atPath: store.committedFileURL.path))
        #expect(try await tokenStore.load(roomID: room, playerID: hostID) == credential)
    }

    @Test func guestFactoryLoadsItsPrivateArchiveAndReconnectUsesContinuousEventsBeforeSnapshot() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = InMemorySecureItemAdapter()
        let tokenStore = RoomTokenStore(adapter: adapter)
        let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x78, count: 32))
        let factory = SessionPersistenceFactory(baseDirectory: directory, tokenStore: tokenStore, keyProvider: key)
        let hostID = GameCore.PlayerID(rawValue: "host")
        try await tokenStore.save(.init(roomID: room, playerID: hostID, reconnectToken: .init(rawValue: "host-token")))
        try await tokenStore.save(.init(roomID: room, playerID: player, reconnectToken: .init(rawValue: "right-token")))

        let hostFixture = try await makeRecoveryFixture(windowVersions: [3, 4], persistedVersion: 4)
        let hostStore = SnapshotStore(directory: factory.directory(roomID: room, playerID: hostID), keyProvider: key)
        try await hostStore.save(hostFixture.archive)
        let guestArchive = SessionArchive.guest(
            protocolVersion: 1, rulesetVersion: "rules-v1",
            hostPlayerID: hostID,
            snapshot: makeSnapshot(recipient: player, opponentHand: nil, version: 2),
            eventWindow: [], tokenReference: .init(roomID: room, playerID: player), commitSequence: 2
        )
        let guestStore = SnapshotStore(directory: factory.directory(roomID: room, playerID: player), keyProvider: key)
        try await guestStore.save(guestArchive)

        let hub = LoopbackTransportHub()
        let recorder = RecoveryPayloadRecordingTransport(base: hub.makeTransport(peerID: hostID))
        let host = try await factory.makeCoordinator(configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room, playerID: hostID,
            reconnectToken: .init(rawValue: "ignored"), hostPlayerID: hostID
        ), role: .host, transport: recorder, rulesMode: .fixtureOnlyLegacy)
        let guest = try await factory.makeCoordinator(configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room, playerID: player,
            reconnectToken: .init(rawValue: "ignored"), hostPlayerID: hostID
        ), role: .guest, transport: hub.makeTransport(peerID: player),
           rulesMode: .fixtureOnlyLegacy)

        #expect(await guest.snapshot?.authoritativeVersion == .init(rawValue: 2))
        try await host.createRoom(); try await guest.joinRoom()
        try await eventually { await guest.snapshot?.authoritativeVersion == .init(rawValue: 4) }
        #expect(await recorder.recoveryPayloadKinds == [.clientEvent, .clientEvent])
    }

    private func makeRailPreparedChecksumArchive() -> (
        archive: SessionArchive,
        playerIDs: [GameCore.PlayerID],
        railDetails: GameCore.GameTransitionEvent.RailPreparedDetails
    ) {
        let roomID = GameCore.RoomID(rawValue: "RAIL-CHECKSUM")
        let hostID = GameCore.PlayerID(rawValue: "host")
        let playerIDs = [hostID] + (0..<12).map {
            GameCore.PlayerID(rawValue: String(format: "guest-%02d", $0))
        }
        let railDetails = GameCore.GameTransitionEvent.RailPreparedDetails(
            removedPlacementIDs: ["canal-only"],
            handCounts: Dictionary(uniqueKeysWithValues: playerIDs.reversed().map { ($0, 8) })
        )
        let state = GameCore.AuthoritativeGameState(
            roomID: roomID,
            players: playerIDs.map {
                .init(
                    id: $0,
                    reconnectToken: .init(rawValue: "token-\($0.rawValue)"),
                    hand: ["card-\($0.rawValue)"]
                )
            },
            activePlayerID: hostID,
            turn: 1,
            actionNumber: 1,
            authoritativeVersion: .init(rawValue: 1),
            discardPile: []
        )
        let visiblePlayers = playerIDs.map {
            GameCore.VisiblePlayer(
                id: $0,
                handCount: 1,
                hand: $0 == hostID ? ["card-host"] : nil
            )
        }
        let snapshot = GameCore.ViewSnapshot(
            roomID: roomID,
            recipient: hostID,
            players: visiblePlayers,
            activePlayerID: hostID,
            turn: 1,
            actionNumber: 1,
            authoritativeVersion: .init(rawValue: 1),
            discardPile: [],
            checksum: try! GameCore.snapshotChecksum(
                roomID: roomID,
                recipient: hostID,
                players: visiblePlayers,
                activePlayerID: hostID,
                turn: 1,
                actionNumber: 1,
                authoritativeVersion: .init(rawValue: 1),
                discardPile: []
            )
        )
        let event = GameCore.AuthoritativeGameEvent(
            roomID: roomID,
            actor: hostID,
            previousVersion: .init(rawValue: 0),
            version: .init(rawValue: 1),
            actionNumber: 1,
            payload: .passed(discardedCardID: "card-host"),
            transitions: [.railPrepared(railDetails)]
        )
        let envelope = SessionProtocol.SessionEnvelope(
            protocolVersion: 1,
            rulesetVersion: "rules-v1",
            roomID: roomID,
            messageID: .init(rawValue: "rail-prepared"),
            senderID: hostID,
            recipientID: hostID,
            authoritativeVersion: .init(rawValue: 1),
            payload: .clientEvent(.init(event: event, snapshot: snapshot))
        )
        return (
            archive: .host(
                protocolVersion: 1,
                rulesetVersion: "rules-v1",
                recipientID: hostID,
                state: state,
                gameState: .legacyCompatible(state, rulesetVersion: "rules-v1"),
                eventWindows: [hostID: [envelope]],
                tokenReferences: playerIDs.map { .init(roomID: roomID, playerID: $0) },
                peersNeedingRecovery: Set(playerIDs.dropFirst()),
                commitSequence: 1
            ),
            playerIDs: playerIDs,
            railDetails: railDetails
        )
    }

    private func makeLegacySchema4EnvelopeData(
        archive: SessionArchive
    ) throws -> (data: Data, checksum: String) {
        let currentEnvelope = try SnapshotEnvelope(archive: archive)
        let encoded = try JSONEncoder.canonical.encode(currentEnvelope)
        var root = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        func legacyOrderedValue(_ value: Any, fieldName: String? = nil) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.reduce(into: [String: Any]()) { result, entry in
                    result[entry.key] = legacyOrderedValue(entry.value, fieldName: entry.key)
                }
            }
            if let array = value as? [Any] {
                let values = array.map { legacyOrderedValue($0) }
                switch fieldName {
                case "eventWindows", "handCounts":
                    let pairs = stride(from: 0, to: values.count, by: 2).map {
                        Array(values[$0..<min($0 + 2, values.count)])
                    }
                    return pairs.reversed().flatMap { $0 }
                case "peersNeedingRecovery":
                    return Array(values.reversed())
                default:
                    return values
                }
            }
            return value
        }

        let archiveObject = legacyOrderedValue(try #require(root["archive"]))
        let archiveData = try JSONSerialization.data(
            withJSONObject: archiveObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let checksum = SHA256.hash(data: archiveData)
            .map { String(format: "%02x", $0) }
            .joined()
        root["archive"] = archiveObject
        root["checksum"] = checksum
        root["schemaVersion"] = 4
        return (
            try JSONSerialization.data(
                withJSONObject: root,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ),
            checksum
        )
    }

    private func makeGuestArchive(sequence: UInt64) -> SessionArchive {
        .guest(
            protocolVersion: 1,
            rulesetVersion: "rules-v1",
            hostPlayerID: .init(rawValue: "host"),
            snapshot: makeSnapshot(recipient: player, opponentHand: nil, version: Int(sequence)),
            eventWindow: [],
            tokenReference: .init(roomID: room, playerID: player),
            commitSequence: sequence
        )
    }

    private func makeRecoveryFixture(
        windowVersions: [Int],
        persistedVersion: Int
    ) async throws -> (
        coordinator: RecoveryCoordinator,
        tokenStore: RoomTokenStore,
        archive: SessionArchive
    ) {
        let tokenAdapter = InMemorySecureItemAdapter()
        let tokenStore = RoomTokenStore(adapter: tokenAdapter)
        try await tokenStore.save(.init(
            roomID: room, playerID: .init(rawValue: "host"), reconnectToken: .init(rawValue: "host-token")
        ))
        try await tokenStore.save(.init(
            roomID: room, playerID: player, reconnectToken: .init(rawValue: "right-token")
        ))
        let state = GameCore.AuthoritativeGameState(
            roomID: room,
            players: [
                .init(id: .init(rawValue: "host"), reconnectToken: .init(rawValue: "host-token"), hand: ["host-secret"]),
                .init(id: player, reconnectToken: .init(rawValue: "right-token"), hand: ["card-private"]),
            ],
            activePlayerID: player, turn: persistedVersion + 1, actionNumber: persistedVersion,
            authoritativeVersion: .init(rawValue: persistedVersion), discardPile: []
        )
        let events = windowVersions.map { version in
            makeRecoveryEnvelope(version: version, persistedState: state)
        }
        let archive = SessionArchive.host(
            protocolVersion: 1, rulesetVersion: "rules-v1", recipientID: .init(rawValue: "host"),
            state: state,
            gameState: .legacyCompatible(state, rulesetVersion: "rules-v1"),
            eventWindows: [player: events],
            tokenReferences: [
                .init(roomID: room, playerID: .init(rawValue: "host")),
                .init(roomID: room, playerID: player),
            ], peersNeedingRecovery: [], commitSequence: UInt64(persistedVersion)
        )
        return (RecoveryCoordinator(tokenStore: tokenStore), tokenStore, archive)
    }

    private func makeHostArchive(
        roomID: GameCore.RoomID,
        hostID: GameCore.PlayerID
    ) async throws -> SessionArchive {
        let state = GameCore.AuthoritativeGameState(
            roomID: roomID,
            players: [
                .init(id: hostID, reconnectToken: .init(rawValue: "never-persist-this-token"), hand: ["host-card"]),
                .init(id: player, reconnectToken: .init(rawValue: "never-persist-guest-token"), hand: ["guest-card"]),
            ],
            activePlayerID: hostID, turn: 1, actionNumber: 0,
            authoritativeVersion: .init(rawValue: 0), discardPile: []
        )
        return .host(
            protocolVersion: 1, rulesetVersion: "rules-v1", recipientID: hostID,
            state: state,
            gameState: .legacyCompatible(state, rulesetVersion: "rules-v1"),
            eventWindows: [:],
            tokenReferences: [
                .init(roomID: roomID, playerID: hostID),
                .init(roomID: roomID, playerID: player),
            ], peersNeedingRecovery: [], commitSequence: 0
        )
    }

    private func makeCompleteHostArchive(
        roomID: GameCore.RoomID,
        hostID: GameCore.PlayerID,
        catalog: GameCore.VerifiedGameDataCatalog,
        tokenStore: RoomTokenStore
    ) async throws -> SessionArchive {
        let guestID = player
        var selectedState: GameCore.GameState?
        for seed in 1...100 {
            var setup = GameCore.SetupRules(seed: UInt64(seed))
            let candidate = try setup.makeGame(catalog: catalog, playerIDs: [hostID, guestID]).state
            if candidate.activePlayerID == hostID {
                selectedState = candidate
                break
            }
        }
        let gameState = try #require(selectedState)
        let tokens: [GameCore.PlayerID: GameCore.ReconnectToken] = [
            hostID: .init(rawValue: "host-secret"),
            guestID: .init(rawValue: "guest-secret"),
        ]
        for (playerID, token) in tokens {
            try await tokenStore.save(.init(
                roomID: roomID, playerID: playerID, reconnectToken: token
            ))
        }
        let engine = try gameState.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        return .host(
            protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion,
            recipientID: hostID, state: engine.state, gameState: engine.gameState,
            eventWindows: [:],
            tokenReferences: [
                .init(roomID: roomID, playerID: hostID),
                .init(roomID: roomID, playerID: guestID),
            ], peersNeedingRecovery: [], commitSequence: 0
        )
    }

    private func resourceSources(
        level: GameCore.IndustryDefinition.Level,
        locationID: String,
        state: GameCore.GameState,
        catalog: GameCore.VerifiedGameDataCatalog
    ) throws -> [GameCore.ResourceSource] {
        let requirements = Array(repeating: GameCore.ResourceKind.coal, count: level.coalCost)
            + Array(repeating: .iron, count: level.ironCost)
            + Array(repeating: .beer, count: level.beerCost)
        return try requirements.map { resource in
            try #require(GameCore.GameRulesEngine.legalResourceSources(
                resource: resource, consumerLocationID: locationID, context: .standard,
                state: state, catalog: catalog
            ).first)
        }
    }

    private func makePersistentCoordinatorPair(
        catalog: GameCore.VerifiedGameDataCatalog? = nil
    ) -> (
        host: SessionCoordinator,
        guest: SessionCoordinator,
        persistence: RecordingSessionArchivePersistence,
        failures: PersistenceSendFailureControl,
        observations: AtomicCommitObservation
    ) {
        let hostID = GameCore.PlayerID(rawValue: "host")
        let hub = LoopbackTransportHub()
        let persistence = RecordingSessionArchivePersistence()
        let failures = PersistenceSendFailureControl()
        let observations = AtomicCommitObservation()
        let rulesetVersion = catalog?.catalog.rulesetVersion ?? "rules-v1"
        let hostTransport = PersistenceSelectiveFailingTransport(
            base: hub.makeTransport(peerID: hostID), failures: failures,
            persistence: persistence, observations: observations
        )
        let host = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: rulesetVersion, roomID: room,
                playerID: hostID, reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
            ),
            transport: hostTransport,
            persistence: persistence,
            rulesMode: catalog.map(SessionCoordinator.RulesMode.verified) ?? .fixtureOnlyLegacy
        )
        let guest = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: rulesetVersion, roomID: room,
                playerID: player, reconnectToken: .init(rawValue: "right-token"), hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: player),
            rulesMode: catalog.map(SessionCoordinator.RulesMode.verified) ?? .fixtureOnlyLegacy
        )
        return (host, guest, persistence, failures, observations)
    }

    private func verifiedCatalog() throws -> GameCore.VerifiedGameDataCatalog {
        let paths = ["map.json", "industries.json", "cards.json", "merchants.json", "income-track.json"]
        let files = try Dictionary(uniqueKeysWithValues: paths.map { path in
            let name = String(path.dropLast(".json".count))
            let url = try #require(Bundle.main.url(forResource: name, withExtension: "json"))
            return (path, try Data(contentsOf: url))
        })
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: "v2018.11", verificationStatus: .verified,
            files: paths.map { .init(path: $0, sha256: GameCore.GameDataLoader.sha256(files[$0]!)) },
            sources: [.init(
                id: "persistence-build-network", url: "https://example.invalid/rules",
                component: "rules", version: "2018.11", page: "all",
                transcriber: "test", transcribedOn: "2026-08-18",
                checker: "independent-test", checkedOn: "2026-08-18"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: JSONEncoder().encode(manifest), files: files
        )
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PersistenceRecoveryTimeout()
    }

    @MainActor
    private func eventuallyMainActor(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PersistenceRecoveryTimeout()
    }

    private func makeRecoveryEnvelope(
        version: Int,
        persistedState: GameCore.AuthoritativeGameState
    ) -> SessionProtocol.SessionEnvelope {
        let players = [
            GameCore.VisiblePlayer(id: .init(rawValue: "host"), handCount: 1, hand: nil),
            GameCore.VisiblePlayer(id: player, handCount: 1, hand: ["card-private"]),
        ]
        let snapshot = GameCore.ViewSnapshot(
            roomID: room, recipient: player, players: players, activePlayerID: player,
            turn: version + 1, actionNumber: version,
            authoritativeVersion: .init(rawValue: version), discardPile: [],
            checksum: try! GameCore.snapshotChecksum(
                roomID: room, recipient: player, players: players, activePlayerID: player,
                turn: version + 1, actionNumber: version,
                authoritativeVersion: .init(rawValue: version), discardPile: []
            )
        )
        let event = GameCore.AuthoritativeGameEvent(
            roomID: room, actor: .init(rawValue: "host"),
            previousVersion: .init(rawValue: version - 1),
            version: .init(rawValue: version), actionNumber: version,
            payload: .passed(discardedCardID: "discard-\(version)")
        )
        return .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            messageID: .init(rawValue: "recovery-\(version)"), senderID: .init(rawValue: "host"),
            recipientID: player, authoritativeVersion: .init(rawValue: version),
            payload: .clientEvent(.init(event: event, snapshot: snapshot))
        )
    }

    private func expectedGuest() -> SnapshotExpectation {
        .init(protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room, recipientID: player, role: .guest)
    }

    private func makeSnapshot(
        recipient: GameCore.PlayerID,
        opponentHand: [String]?,
        version: Int
    ) -> GameCore.ViewSnapshot {
        let players = [
            GameCore.VisiblePlayer(id: recipient, handCount: 1, hand: ["card-private"]),
            GameCore.VisiblePlayer(id: .init(rawValue: "host"), handCount: 2, hand: opponentHand),
        ]
        return GameCore.ViewSnapshot(
            roomID: room, recipient: recipient, players: players,
            activePlayerID: recipient, turn: version + 1, actionNumber: version,
            authoritativeVersion: .init(rawValue: version), discardPile: [],
            checksum: try! GameCore.snapshotChecksum(
                roomID: room, recipient: recipient, players: players, activePlayerID: recipient,
                turn: version + 1, actionNumber: version,
                authoritativeVersion: .init(rawValue: version), discardPile: []
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndustrialCity-Task15-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func writeUnchecked(_ archive: SessionArchive, key: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encrypted = try SnapshotCrypto.seal(
            JSONEncoder.canonical.encode(try SnapshotEnvelope(archive: archive)), keyData: key
        )
        try encrypted.write(to: url)
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

    private func fixtureRestoredState(_ archive: SessionArchive) -> GameCore.AuthoritativeGameState {
        guard case let .host(host) = archive.payload else {
            preconditionFailure("Expected host archive")
        }
        return .init(
            roomID: host.authoritativeState.roomID,
            players: host.authoritativeState.players.map {
                .init(id: $0.id, reconnectToken: .init(rawValue: "fixture"), hand: $0.hand)
            },
            activePlayerID: host.authoritativeState.activePlayerID,
            turn: host.authoritativeState.turn, actionNumber: host.authoritativeState.actionNumber,
            authoritativeVersion: host.authoritativeState.authoritativeVersion,
            discardPile: host.authoritativeState.discardPile
        )
    }
}

private final class RecordingRecoveryMaterialCleaner: RecoveryMaterialCleaning, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RoomTokenReference] = []
    var clearedReferences: [RoomTokenReference] { lock.withLock { storage } }
    func clearRecoveryMaterial(for reference: RoomTokenReference) async throws {
        lock.withLock { storage.append(reference) }
    }
}

private actor RecordingSessionArchivePersistence: SessionArchivePersisting {
    private(set) var savedArchives: [SessionArchive] = []
    private(set) var attemptedArchives: [SessionArchive] = []
    private var shouldFail = false
    private var saveDelay: Duration?
    private(set) var saveAttemptCount = 0
    private var failingSaveNumbers: Set<Int> = []
    func save(_ archive: SessionArchive) async throws {
        attemptedArchives.append(archive)
        saveAttemptCount += 1
        let attempt = saveAttemptCount
        if let saveDelay { try await Task.sleep(for: saveDelay) }
        if shouldFail || failingSaveNumbers.contains(attempt) {
            throw SessionPersistenceError.saveFailed
        }
        savedArchives.append(archive)
    }
    func failSaves(_ value: Bool) { shouldFail = value }
    func failSave(number: Int) { failingSaveNumbers.insert(number) }
    func delaySaves(_ value: Duration?) { saveDelay = value }
}

private actor PausedSessionArchivePersistence: SessionArchivePersisting {
    private(set) var attemptedSequences: [UInt64] = []
    private(set) var savedSequences: [UInt64] = []
    private var isFirstSavePaused = false
    private var isFirstSaveReleased = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func save(_ archive: SessionArchive) async throws {
        attemptedSequences.append(archive.commitSequence)
        if attemptedSequences.count == 1, !isFirstSaveReleased {
            isFirstSavePaused = true
            blockedContinuation?.resume()
            blockedContinuation = nil
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        savedSequences.append(archive.commitSequence)
    }

    func waitUntilFirstSaveIsPaused() async {
        guard !isFirstSavePaused else { return }
        await withCheckedContinuation { blockedContinuation = $0 }
    }

    func releaseFirstSave() {
        isFirstSaveReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor AtomicCommitObservation {
    private(set) var precommitVersionsSeenBeforeClientEvent: [GameCore.AuthoritativeVersion?] = []
    private(set) var recoverySetsSeenBeforeClientEvent: [Set<GameCore.PlayerID>] = []
    private(set) var clientEventSendCount = 0

    func recordClientEventSend(latestArchive: SessionArchive?) {
        clientEventSendCount += 1
        precommitVersionsSeenBeforeClientEvent.append(latestArchive?.authoritativeVersion)
        guard case let .host(payload) = latestArchive?.payload else {
            recoverySetsSeenBeforeClientEvent.append([])
            return
        }
        recoverySetsSeenBeforeClientEvent.append(payload.peersNeedingRecovery)
    }
}

private actor ClientEventSendBarrier {
    private let version: Int
    private let peer: GameCore.PlayerID
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isBlocked = false
    private var isReleased = false

    init(version: Int, peer: GameCore.PlayerID) {
        self.version = version
        self.peer = peer
    }

    func waitIfNeeded(for envelope: SessionProtocol.SessionEnvelope, peer: GameCore.PlayerID) async {
        guard envelope.authoritativeVersion.rawValue == version,
              case .clientEvent = envelope.payload,
              peer == self.peer,
              !isReleased else { return }
        isBlocked = true
        blockedContinuation?.resume()
        blockedContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { blockedContinuation = $0 }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor PersistenceSendFailureControl {
    private var failedPeers: Set<GameCore.PlayerID> = []
    func failSends(to player: GameCore.PlayerID) { failedPeers.insert(player) }
    func shouldFail(_ player: GameCore.PlayerID) -> Bool { failedPeers.contains(player) }
}

private actor PersistenceSelectiveFailingTransport: Transport {
    nonisolated let events: AsyncStream<TransportEvent>
    private let base: LoopbackTransport
    private let failures: PersistenceSendFailureControl
    private let persistence: RecordingSessionArchivePersistence
    private let observations: AtomicCommitObservation
    private let barrier: ClientEventSendBarrier?

    init(
        base: LoopbackTransport,
        failures: PersistenceSendFailureControl,
        persistence: RecordingSessionArchivePersistence,
        observations: AtomicCommitObservation,
        barrier: ClientEventSendBarrier? = nil
    ) {
        self.base = base
        self.failures = failures
        self.persistence = persistence
        self.observations = observations
        self.barrier = barrier
        events = base.events
    }

    func startHosting(roomID: GameCore.RoomID, port: UInt16?) async throws {
        try await base.startHosting(roomID: roomID, port: port)
    }
    func browse() async throws { try await base.browse() }
    func connect(to peer: GameCore.PlayerID) async throws { try await base.connect(to: peer) }
    func send(_ data: Data, to peer: GameCore.PlayerID) async throws {
        if let envelope = try? JSONDecoder().decode(SessionProtocol.SessionEnvelope.self, from: data),
           case .clientEvent = envelope.payload {
            await observations.recordClientEventSend(latestArchive: persistence.savedArchives.last)
            await barrier?.waitIfNeeded(for: envelope, peer: peer)
        }
        if await failures.shouldFail(peer) { throw TransportError.connectionFailed }
        try await base.send(data, to: peer)
    }
    func disconnect() async { await base.disconnect() }
}

private enum RecordedRecoveryPayloadKind: Equatable, Sendable {
    case clientEvent
    case viewSnapshot
}

private actor RecoveryPayloadRecordingTransport: Transport {
    nonisolated let events: AsyncStream<TransportEvent>
    private let base: LoopbackTransport
    private(set) var recoveryPayloadKinds: [RecordedRecoveryPayloadKind] = []

    init(base: LoopbackTransport) {
        self.base = base
        events = base.events
    }

    func startHosting(roomID: GameCore.RoomID, port: UInt16?) async throws {
        try await base.startHosting(roomID: roomID, port: port)
    }
    func browse() async throws { try await base.browse() }
    func connect(to peer: GameCore.PlayerID) async throws { try await base.connect(to: peer) }
    func send(_ data: Data, to peer: GameCore.PlayerID) async throws {
        if let envelope = try? JSONDecoder().decode(SessionProtocol.SessionEnvelope.self, from: data) {
            switch envelope.payload {
            case .clientEvent: recoveryPayloadKinds.append(.clientEvent)
            case .viewSnapshot: recoveryPayloadKinds.append(.viewSnapshot)
            default: break
            }
        }
        try await base.send(data, to: peer)
    }
    func disconnect() async { await base.disconnect() }
}

private actor RecoveryDeliveryGate {
    private let pausedVersion: Int
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(pausedVersion: Int) {
        self.pausedVersion = pausedVersion
    }

    func waitIfNeeded(for envelope: SessionProtocol.SessionEnvelope) async {
        guard envelope.authoritativeVersion.rawValue == pausedVersion,
              case .clientEvent = envelope.payload,
              !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor GatedRecoveryTransport: Transport {
    nonisolated let events: AsyncStream<TransportEvent>
    private let base: LoopbackTransport
    private let gate: RecoveryDeliveryGate

    init(base: LoopbackTransport, gate: RecoveryDeliveryGate) {
        self.base = base
        self.gate = gate
        events = base.events
    }

    func startHosting(roomID: GameCore.RoomID, port: UInt16?) async throws {
        try await base.startHosting(roomID: roomID, port: port)
    }
    func browse() async throws { try await base.browse() }
    func connect(to peer: GameCore.PlayerID) async throws { try await base.connect(to: peer) }
    func send(_ data: Data, to peer: GameCore.PlayerID) async throws {
        if let envelope = try? JSONDecoder().decode(SessionProtocol.SessionEnvelope.self, from: data) {
            await gate.waitIfNeeded(for: envelope)
        }
        try await base.send(data, to: peer)
    }
    func disconnect() async { await base.disconnect() }
}

private struct PersistenceRecoveryTimeout: Error {}

private extension RecoveryRequest {
    func replacing(
        token: GameCore.ReconnectToken? = nil,
        authenticatedHost: GameCore.PlayerID? = nil,
        playerID: GameCore.PlayerID? = nil,
        fromVersion: GameCore.AuthoritativeVersion? = nil
    ) -> RecoveryRequest {
        RecoveryRequest(
            protocolVersion: protocolVersion,
            rulesetVersion: rulesetVersion,
            roomID: roomID,
            playerID: playerID ?? self.playerID,
            reconnectToken: token ?? reconnectToken,
            hostPlayerID: hostPlayerID,
            authenticatedRemotePlayerID: authenticatedHost ?? authenticatedRemotePlayerID,
            fromVersion: fromVersion ?? self.fromVersion
        )
    }
}

private extension SessionArchive {
    func replacing(rulesetVersion: String) -> SessionArchive {
        SessionArchive(
            protocolVersion: protocolVersion,
            rulesetVersion: rulesetVersion,
            roomID: roomID,
            recipientID: recipientID,
            role: role,
            authoritativeVersion: authoritativeVersion,
            commitSequence: commitSequence,
            payload: payload
        )
    }
}

private struct FixedSnapshotKeyProvider: SnapshotKeyProvider {
    let key: Data
    func keyData() throws -> Data { key }
}

private struct InterruptingSnapshotFileWriter: SnapshotFileWriting {
    func replaceCommittedFile(with data: Data, committedURL: URL, temporaryPrefix: String) throws {
        let temporaryURL = committedURL.deletingLastPathComponent()
            .appendingPathComponent("\(temporaryPrefix)interrupted")
        try data.prefix(max(1, data.count / 2)).write(to: temporaryURL)
        throw SnapshotStoreError.writeInterrupted
    }
}

private final class InMemorySecureItemAdapter: SecureItemAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var adds = 0
    private var updates = 0
    private var metadata: [String] = []

    var addCount: Int { lock.withLock { adds } }
    var updateCount: Int { lock.withLock { updates } }
    var lookupMetadata: [String] { lock.withLock { metadata } }
    var allStoredData: [Data] { lock.withLock { Array(storage.values) } }

    func read(service: String, account: String) throws -> Data? {
        lock.withLock {
            metadata.append("\(service)|\(account)")
            return storage[key(service: service, account: account)]
        }
    }

    func readAll(service: String) throws -> [Data] {
        lock.withLock {
            metadata.append("\(service)|*")
            let prefix = "\(service)|"
            return storage.compactMap { key, value in key.hasPrefix(prefix) ? value : nil }
        }
    }

    func add(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            metadata.append("\(service)|\(account)")
            let itemKey = key(service: service, account: account)
            guard storage[itemKey] == nil else { throw SecureItemAdapterError.duplicateItem }
            storage[itemKey] = data
            adds += 1
        }
    }

    func update(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            metadata.append("\(service)|\(account)")
            let itemKey = key(service: service, account: account)
            guard storage[itemKey] != nil else { throw SecureItemAdapterError.itemNotFound }
            storage[itemKey] = data
            updates += 1
        }
    }

    func delete(service: String, account: String) throws {
        lock.withLock {
            metadata.append("\(service)|\(account)")
            storage[key(service: service, account: account)] = nil
        }
    }

    private func key(service: String, account: String) -> String { "\(service)|\(account)" }
}
