import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct SessionCoordinatorTests {
    private let room = GameCore.RoomID(rawValue: "TEST42")
    private let hostID = GameCore.PlayerID(rawValue: "host")
    private let guestID = GameCore.PlayerID(rawValue: "guest")

    @Test func verifiedRestoredHostImmediatelyProjectsCatalogAndServesLegalQuery() async throws {
        let catalog = try verifiedCatalog()
        var setup = GameCore.SetupRules(seed: 7)
        var state = try setup.makeGame(catalog: catalog, playerIDs: [hostID, guestID]).state
        state.activePlayerID = hostID
        let tokens: [GameCore.PlayerID: GameCore.ReconnectToken] = [
            hostID: .init(rawValue: "t-host"), guestID: .init(rawValue: "t-guest"),
        ]
        let engine = try state.makeHostEngine(roomID: room, reconnectTokens: tokens, protocolVersion: 2)
        let coordinator = try SessionCoordinator(
            configuration: .init(
                protocolVersion: 2, rulesetVersion: state.rulesetVersion, roomID: room,
                playerID: hostID, reconnectToken: tokens[hostID]!, hostPlayerID: hostID
            ),
            restored: .init(
                state: engine.state, gameState: state, eventWindows: [:],
                peersNeedingRecovery: [], commitSequence: 1
            ),
            transport: LoopbackTransportHub().makeTransport(peerID: hostID),
            rulesMode: .verified(catalog)
        )
        let snapshot = try #require(await coordinator.snapshot)
        let cardID = try #require(snapshot.players.first(where: { $0.id == hostID })?.hand?.first)
        #expect(snapshot.match != nil)

        try await coordinator.requestLegalOptions(
            requestID: "restored-pass",
            draft: .init(action: .pass, cardID: cardID, selections: [])
        )
        #expect(await coordinator.lastLegalResponse?.completePayload == .pass(.init(cardID: cardID)))
    }

    @Test func directRejectionCanBeRevisedAndQueriedWithoutAnIntermediateEvent() async throws {
        let catalog = try verifiedCatalog()
        var setup = GameCore.SetupRules(seed: 9)
        var state = try setup.makeGame(catalog: catalog, playerIDs: [hostID, guestID]).state
        state.activePlayerID = hostID
        let tokens: [GameCore.PlayerID: GameCore.ReconnectToken] = [
            hostID: .init(rawValue: "t-host"), guestID: .init(rawValue: "t-guest"),
        ]
        let engine = try state.makeHostEngine(roomID: room, reconnectTokens: tokens, protocolVersion: 2)
        let coordinator = try SessionCoordinator(
            configuration: .init(
                protocolVersion: 2, rulesetVersion: state.rulesetVersion, roomID: room,
                playerID: hostID, reconnectToken: tokens[hostID]!, hostPlayerID: hostID
            ), restored: .init(
                state: engine.state, gameState: state, eventWindows: [:],
                peersNeedingRecovery: [], commitSequence: 1
            ), transport: LoopbackTransportHub().makeTransport(peerID: hostID),
            rulesMode: .verified(catalog)
        )
        let version = try #require(await coordinator.snapshot?.authoritativeVersion)
        try await coordinator.submit(.pass(.init(cardID: "not-in-hand")))
        #expect(await coordinator.lastIntentRejection?.reasonCode == .missingDiscardCard)
        #expect(await coordinator.snapshot?.authoritativeVersion == version)

        let cardID = try #require(await coordinator.snapshot?.players
            .first(where: { $0.id == hostID })?.hand?.first)
        try await coordinator.requestLegalOptions(
            requestID: "revise-pass",
            draft: .init(action: .pass, cardID: cardID, selections: [])
        )
        #expect(await coordinator.lastIntentRejection == nil)
        #expect(await coordinator.lastLegalResponse?.completePayload == .pass(.init(cardID: cardID)))
        #expect(await coordinator.snapshot?.authoritativeVersion == version)
    }

    @Test func restoredRemoteDebtorReceivesPrivateProjectionPausesOrdinaryIntentAndCompletesForcedSale() async throws {
        let catalog = try verifiedCatalog()
        var setup = GameCore.SetupRules(seed: 1)
        var state = try setup.makeGame(catalog: catalog, playerIDs: [hostID, guestID]).state
        let location = try #require(catalog.catalog.board.locations.first { location in
            location.industrySlots.contains { $0.contains("manufacturer") }
        })
        let slot = try #require(location.industrySlots.firstIndex { $0.contains("manufacturer") })
        let tile = try #require(state.players.first { $0.id == guestID }?
            .industryStacks.first { $0.industryDefinitionID == "manufacturer" }?.tiles.first)
        let guestIndex = try #require(state.players.firstIndex { $0.id == guestID })
        let stackIndex = try #require(state.players[guestIndex].industryStacks.firstIndex {
            $0.industryDefinitionID == "manufacturer"
        })
        state.players[guestIndex].industryStacks[stackIndex].tiles.removeFirst()
        state.players[guestIndex].cash = 0
        state.players[guestIndex].incomePosition = 0
        state.boardIndustryPlacements = [.init(
            placementID: "remote-sale", locationID: location.id, slotIndex: slot,
            ownerID: guestID, tile: tile
        )]
        state.turnPhase = .forcedSale(.init(
            playerID: guestID, shortfall: 1, eligiblePlacementIDs: ["remote-sale"]
        ))
        state.activePlayerID = guestID
        state.actionsRemaining = 0
        state.turnsCompletedInRound = 0
        state.roundIncomeCursor = try #require(state.playerOrder.firstIndex(of: guestID)) + 1
        state.actionNumber = state.playerCount
        state.authoritativeVersion = .init(rawValue: state.playerCount)
        repairCardFixture(&state, catalog: catalog)
        let tokens: [GameCore.PlayerID: GameCore.ReconnectToken] = [
            hostID: .init(rawValue: "t-host"), guestID: .init(rawValue: "t-guest"),
        ]
        let engine = try state.makeHostEngine(roomID: room, reconnectTokens: tokens, protocolVersion: 1)
        let hub = LoopbackTransportHub()
        let host = try SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: room,
                playerID: hostID, reconnectToken: tokens[hostID]!, hostPlayerID: hostID
            ),
            restored: .init(
                state: engine.state, gameState: state, eventWindows: [:],
                peersNeedingRecovery: [], commitSequence: 1
            ),
            transport: hub.makeTransport(peerID: hostID), rulesMode: .verified(catalog)
        )
        let archivedGuest = try JSONDecoder().decode(
            GameCore.ViewSnapshot.self,
            from: JSONEncoder.canonical.encode(try engine.snapshot(for: guestID))
        )
        let guest = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: room,
                playerID: guestID, reconnectToken: tokens[guestID]!, hostPlayerID: hostID
            ),
            restoredGuest: .init(
                snapshot: archivedGuest, eventWindow: [],
                tokenReference: .init(roomID: room, playerID: guestID), hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: guestID), rulesMode: .verified(catalog)
        )
        try await host.createRoom()
        try await guest.joinRoom()
        #expect(await host.forcedSale == nil)
        #expect(await guest.forcedSale == .init(shortfall: 1, eligiblePlacementIDs: ["remote-sale"]))

        let cardID = try #require(await guest.snapshot?.players.first { $0.id == guestID }?.hand?.first)
        try await guest.submit(.pass(.init(cardID: cardID)))
        try await eventually { await guest.lastIntentRejection?.reasonCode == .invalidAction }
        #expect(await guest.snapshot?.authoritativeVersion == .init(rawValue: 2))

        try await guest.submit(.forcedSale(.init(placementIDs: ["remote-sale"])))
        try await eventually {
            let hostVersion = await host.snapshot?.authoritativeVersion
            let guestVersion = await guest.snapshot?.authoritativeVersion
            return hostVersion == .init(rawValue: 3) && guestVersion == .init(rawValue: 3)
        }
        #expect(await host.forcedSale == nil)
        #expect(await guest.forcedSale == nil)
    }

    @Test func hostInternalOverflowPausesForRecoveryAndPreservesDiagnostic() async throws {
        let catalog = try verifiedCatalog()
        var setup = GameCore.SetupRules(seed: 1)
        var state = try setup.makeGame(catalog: catalog, playerIDs: [hostID, guestID]).state
        let hostIndex = try #require(state.players.firstIndex { $0.id == hostID })
        state.activePlayerID = hostID
        state.turnsCompletedInRound = try #require(state.playerOrder.firstIndex(of: hostID))
        state.actionNumber = state.turnsCompletedInRound
        state.authoritativeVersion = .init(rawValue: state.actionNumber)
        repairCardFixture(&state, catalog: catalog)
        state.players[hostIndex].cash = Int.max
        let cardID = try #require(state.players[hostIndex].hand.first?.id)
        let tokens: [GameCore.PlayerID: GameCore.ReconnectToken] = [
            hostID: .init(rawValue: "t-host"), guestID: .init(rawValue: "t-guest"),
        ]
        let engine = try state.makeHostEngine(
            roomID: room, reconnectTokens: tokens, protocolVersion: 1
        )
        let restored = RestoredHostSession(
            state: engine.state, gameState: state, eventWindows: [:],
            peersNeedingRecovery: [], commitSequence: 0
        )
        let coordinator = try SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: room,
                playerID: hostID, reconnectToken: tokens[hostID]!, hostPlayerID: hostID
            ),
            restored: restored, transport: LoopbackTransportHub().makeTransport(peerID: hostID),
            rulesMode: .verified(catalog)
        )
        try await coordinator.createRoom()
        let before = try #require(await coordinator.snapshot)

        try await coordinator.submit(.loan(.init(cardID: cardID)))

        #expect(await coordinator.snapshot == before)
        #expect(await coordinator.lastInternalFailure == .init(code: .arithmeticOverflow))
        #expect(await coordinator.pauseReason == .stateRecovery)
        #expect(await coordinator.recoveryError == .invalidMaterial)

        await #expect(throws: SessionCoordinator.Error.sessionPaused) {
            try await coordinator.pass(discardCardID: cardID)
        }
        #expect(await coordinator.snapshot == before)
        #expect(await coordinator.lastInternalFailure == .init(code: .arithmeticOverflow))
    }

    @Test func pausedHostRejectsRemoteIntentWithStableInternalFailureWithoutAdvancingEitherPeer() async throws {
        let catalog = try verifiedCatalog()
        var setup = GameCore.SetupRules(seed: 1)
        var state = try setup.makeGame(catalog: catalog, playerIDs: [hostID, guestID]).state
        let hostIndex = try #require(state.players.firstIndex { $0.id == hostID })
        state.activePlayerID = hostID
        state.turnsCompletedInRound = try #require(state.playerOrder.firstIndex(of: hostID))
        state.actionNumber = state.turnsCompletedInRound
        state.authoritativeVersion = .init(rawValue: state.actionNumber)
        repairCardFixture(&state, catalog: catalog)
        state.players[hostIndex].cash = Int.max
        let loanCardID = try #require(state.players[hostIndex].hand.first?.id)
        let guestCardID = try #require(state.players.first(where: { $0.id == guestID })?.hand.first?.id)
        let tokens: [GameCore.PlayerID: GameCore.ReconnectToken] = [
            hostID: .init(rawValue: "t-host"), guestID: .init(rawValue: "t-guest"),
        ]
        let engine = try state.makeHostEngine(
            roomID: room, reconnectTokens: tokens, protocolVersion: 1
        )
        let hub = LoopbackTransportHub()
        let host = try SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: room,
                playerID: hostID, reconnectToken: tokens[hostID]!, hostPlayerID: hostID
            ),
            restored: .init(
                state: engine.state, gameState: state, eventWindows: [:],
                peersNeedingRecovery: [], commitSequence: 0
            ),
            transport: hub.makeTransport(peerID: hostID), rulesMode: .verified(catalog)
        )
        let guestSnapshot = try engine.snapshot(for: guestID)
        let guest = SessionCoordinator(
            configuration: .init(
                protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: room,
                playerID: guestID, reconnectToken: tokens[guestID]!, hostPlayerID: hostID
            ),
            restoredGuest: .init(
                snapshot: guestSnapshot, eventWindow: [],
                tokenReference: .init(roomID: room, playerID: guestID), hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: guestID), rulesMode: .verified(catalog)
        )
        try await host.createRoom()
        try await guest.joinRoom()
        let hostBefore = try #require(await host.snapshot)
        let guestBefore = try #require(await guest.snapshot)

        try await host.submit(.loan(.init(cardID: loanCardID)))
        try await guest.submit(.pass(.init(cardID: guestCardID)))
        try await eventually {
            await guest.lastIntentRejection?.reasonCode == .internalFailure
        }

        #expect(await host.snapshot == hostBefore)
        #expect(await guest.snapshot == guestBefore)
        #expect(await host.pauseReason == .stateRecovery)
        #expect(await host.lastDeliveryError == nil)
        #expect(await guest.lastIntentRejection?.recoverySuggestion
            == "The host session is paused pending authoritative recovery.")
    }

    @Test func realGameCatalogAwareActionsConvergeThroughLoopback() async throws {
        let catalog = try verifiedCatalog()
        let liveHub = LoopbackTransportHub()
        let host = realCoordinator(
            id: hostID, token: "t-host", transport: liveHub.makeTransport(peerID: hostID), catalog: catalog
        )
        let guest = realCoordinator(
            id: guestID, token: "t-guest", transport: liveHub.makeTransport(peerID: guestID), catalog: catalog
        )
        try await host.createRoom()
        try await guest.joinRoom()
        try await host.setReady(true)
        try await guest.setReady(true)
        try await eventually { await host.readyPlayerIDs.count == 2 }
        try await host.startGame()
        try await eventually { await guest.snapshot != nil }

        var setup = GameCore.SetupRules(seed: 1)
        let initial = try setup.makeGame(catalog: catalog, playerIDs: [hostID, guestID]).state
        let buildActor = try #require(initial.activePlayerID)
        let buildPlayer = try #require(initial.players.first(where: { $0.id == buildActor }))
        let breweryTile = try #require(buildPlayer.industryStacks.first(where: {
            $0.industryDefinitionID == "brewery"
        })?.tiles.first)
        let buildChoice = try #require(buildPlayer.hand.lazy.compactMap { card -> (GameCore.CardInstance, GameCore.BuildTarget)? in
            GameCore.BuildRules.legalBuildTargets(
                actorID: buildActor, cardID: card.id, tile: breweryTile,
                state: initial, catalog: catalog
            ).first.map { (card, $0) }
        }.first)
        let ironSource = try #require(GameCore.GameRulesEngine.legalResourceSources(
            resource: .iron, consumerLocationID: buildChoice.1.locationID,
            context: .standard, state: initial, catalog: catalog
        ).first)
        let buildCoordinator = buildActor == hostID ? host : guest
        try await buildCoordinator.submit(.build(.init(
            cardID: buildChoice.0.id,
            locationID: buildChoice.1.locationID,
            industryDefinitionID: "brewery",
            slotIndex: buildChoice.1.slotIndex,
            resourceSources: [ironSource]
        )))
        try await eventually {
            let hostVersion = await host.snapshot?.authoritativeVersion
            let guestVersion = await guest.snapshot?.authoritativeVersion
            return hostVersion == .init(rawValue: 1) && guestVersion == .init(rawValue: 1)
        }
        let hostBoard = await host.snapshot?.match?.boardIndustryPlacements
        let guestBoard = await guest.snapshot?.match?.boardIndustryPlacements
        #expect(hostBoard == guestBoard)
        #expect(hostBoard?.contains(where: { $0.tile.industryDefinitionID == "brewery" }) == true)
        let hostPublicChecksum = await host.snapshot?.match?.publicChecksum
        let guestPublicChecksum = await guest.snapshot?.match?.publicChecksum
        #expect(hostPublicChecksum == guestPublicChecksum)

        let networkActor = buildActor == hostID ? guestID : hostID
        let networkCoordinator = networkActor == hostID ? host : guest
        let networkCard = try #require(await networkCoordinator.snapshot?.players.first(where: { $0.id == networkActor })?.hand?.first)
        let canalRoute = try #require(catalog.catalog.board.routes.first(where: {
            $0.eras.contains(.canal) && $0.playerCounts.contains(2)
        }))
        try await networkCoordinator.submit(.network(.init(
            cardID: networkCard, routeIDs: [canalRoute.id], coalSources: [], beerSource: nil
        )))
        try await eventually {
            let hostVersion = await host.snapshot?.authoritativeVersion
            let guestVersion = await guest.snapshot?.authoritativeVersion
            return hostVersion == .init(rawValue: 2) && guestVersion == .init(rawValue: 2)
        }
        #expect(await host.snapshot?.actionNumber == 2)
        #expect(await guest.snapshot?.actionNumber == 2)

        let loanActor = try #require(await host.snapshot?.activePlayerID)
        let loanCoordinator = loanActor == hostID ? host : guest
        let loanCard = try #require(await loanCoordinator.snapshot?.players.first(where: {
            $0.id == loanActor
        })?.hand?.first)
        try await loanCoordinator.submit(.loan(.init(cardID: loanCard)))
        try await eventually {
            let hostVersion = await host.snapshot?.authoritativeVersion
            let guestVersion = await guest.snapshot?.authoritativeVersion
            return hostVersion == .init(rawValue: 3) && guestVersion == .init(rawValue: 3)
        }
        #expect(await host.snapshot?.actionNumber == 3)
        #expect(await guest.snapshot?.actionNumber == 3)
    }

    @Test func concurrentStartGameAllowsExactlyOneAuthoritativeSetup() async throws {
        let catalog = try verifiedCatalog()
        let liveHub = LoopbackTransportHub()
        let host = realCoordinator(
            id: hostID, token: "t-host", transport: liveHub.makeTransport(peerID: hostID), catalog: catalog
        )
        let guest = realCoordinator(
            id: guestID, token: "t-guest", transport: liveHub.makeTransport(peerID: guestID), catalog: catalog
        )
        try await host.createRoom(); try await guest.joinRoom()
        try await host.setReady(true); try await guest.setReady(true)
        try await eventually { await host.readyPlayerIDs.count == 2 }

        let first = Task { try await host.startGame() }
        let second = Task { try await host.startGame() }
        let results = await [first.result, second.result]
        #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
        #expect(results.contains { result in
            guard case .failure(let error) = result else { return false }
            return error as? SessionCoordinator.Error == .gameAlreadyStarted
        })
    }

    @Test func startGameRejectsReadySeatThatDisconnectedBeforeInitialSnapshots() async throws {
        let catalog = try verifiedCatalog()
        let liveHub = LoopbackTransportHub()
        let host = realCoordinator(
            id: hostID, token: "t-host", transport: liveHub.makeTransport(peerID: hostID), catalog: catalog
        )
        let guest = realCoordinator(
            id: guestID, token: "t-guest", transport: liveHub.makeTransport(peerID: guestID), catalog: catalog
        )
        try await host.createRoom()
        try await guest.joinRoom()
        try await host.setReady(true)
        try await guest.setReady(true)
        try await eventually { await host.readyPlayerIDs.count == 2 }

        await guest.disconnect()
        try await eventually {
            let readyCount = await host.readyPlayerIDs.count
            let connected = await host.connectedPlayerIDs
            return readyCount == 2 && connected == [self.hostID]
        }

        await #expect(throws: SessionCoordinator.Error.notAllPlayersReady) {
            try await host.startGame()
        }
        #expect(await host.snapshot == nil)
    }

    @Test func startedGameRejectsANewSeatButStillAllowsAssignedSeatReconnect() async throws {
        let pair = makePair()
        try await pair.host.createRoom()
        try await pair.guest.joinRoom()
        try await pair.host.setReady(true)
        try await pair.guest.setReady(true)
        try await eventually { await pair.host.readyPlayerIDs.count == 2 }
        try await pair.host.startGame()
        try await eventually { await pair.guest.snapshot != nil }

        let late = coordinator(
            id: "late-player", token: "late-token",
            transport: pair.hub.makeTransport(peerID: .init(rawValue: "late-player"))
        )
        await #expect(throws: SessionCoordinator.Error.roomFull) {
            try await late.joinRoom()
        }
        #expect(Set(await pair.host.playerIDs) == [hostID, guestID])

        await pair.guest.disconnect()
        let reconnected = coordinator(
            id: guestID.rawValue, token: "t-guest",
            transport: pair.hub.makeTransport(peerID: .init(rawValue: "guest-reconnected-after-start"))
        )
        try await reconnected.joinRoom()
        try await eventually { await reconnected.snapshot != nil }
        #expect(Set(await pair.host.playerIDs) == [hostID, guestID])
    }

    @Test func activeGuestDisconnectPausesEveryOnlineSeatUntilThatSeatRecovers() async throws {
        let hub = LoopbackTransportHub()
        let guestOneID = GameCore.PlayerID(rawValue: "g1")
        let guestTwoID = GameCore.PlayerID(rawValue: "g2")
        let host = coordinator(
            id: hostID.rawValue, token: "t-host",
            transport: hub.makeTransport(peerID: hostID)
        )
        let guestOne = coordinator(
            id: guestOneID.rawValue, token: "t-g1",
            transport: hub.makeTransport(peerID: guestOneID)
        )
        let guestTwo = coordinator(
            id: guestTwoID.rawValue, token: "t-g2",
            transport: hub.makeTransport(peerID: guestTwoID)
        )

        try await host.createRoom()
        try await guestOne.joinRoom()
        try await guestTwo.joinRoom()
        try await host.setReady(true)
        try await guestOne.setReady(true)
        try await guestTwo.setReady(true)
        try await eventually { await host.readyPlayerIDs.count == 3 }
        try await host.startGame()
        try await eventually { await guestTwo.snapshot != nil }

        let hostCard = try #require(await host.snapshot?.players
            .first(where: { $0.id == hostID })?.hand?.first)
        try await host.pass(discardCardID: hostCard)
        try await eventually { await guestTwo.snapshot?.activePlayerID == guestOneID }

        await guestOne.disconnect()
        try await eventually {
            let hostPause = await host.pauseReason
            let guestTwoPause = await guestTwo.pauseReason
            return hostPause == .actorDisconnected && guestTwoPause == .actorDisconnected
        }
        let secondHostCard = try #require(await host.snapshot?.players
            .first(where: { $0.id == hostID })?.hand?.first)
        await #expect(throws: SessionCoordinator.Error.sessionPaused) {
            try await host.pass(discardCardID: secondHostCard)
        }

        let reconnectedGuestOne = coordinator(
            id: guestOneID.rawValue, token: "t-g1",
            transport: hub.makeTransport(peerID: .init(rawValue: "g1-reconnected"))
        )
        try await reconnectedGuestOne.joinRoom()
        try await eventually {
            let version = await host.snapshot?.authoritativeVersion
            let hostPause = await host.pauseReason
            let guestTwoPause = await guestTwo.pauseReason
            let reconnectedPause = await reconnectedGuestOne.pauseReason
            let reconnectedVersion = await reconnectedGuestOne.snapshot?.authoritativeVersion
            return hostPause == nil
                && guestTwoPause == nil
                && reconnectedPause == nil
                && reconnectedVersion == version
        }
    }

    @Test func appEnvironmentParsesLocalHarnessArgumentsWithoutAffectingDefaultLaunch() {
        #expect(AppEnvironment(arguments: ["app"]).localHarness == nil)
        #expect(AppEnvironment(arguments: ["app", "-online-fixture"]).localHarness == nil)
        #expect(AppEnvironment(arguments: ["app", "-local-role", "host", "-local-room", "TEST42", "-local-port", "43123"]).localHarness
            == .init(role: .host, roomID: .init(rawValue: "TEST42"), port: 43123))
        #expect(AppEnvironment(arguments: ["app", "-local-role", "guest", "-local-room", "TEST42"]).localHarness
            == .init(role: .guest, roomID: .init(rawValue: "TEST42"), port: nil))
        #expect(AppEnvironment(arguments: ["app", "-local-role", "invalid", "-local-room", "TEST42"]).localHarness == nil)
        #expect(AppEnvironment(arguments: ["app", "-local-role", "host", "-local-room", "TEST42"]).runsLocalScriptHarness == false)
        #expect(AppEnvironment(arguments: ["app", "-local-role", "host", "-local-room", "TEST42", "-local-script-harness"]).runsLocalScriptHarness)
        #expect(AppEnvironment(arguments: ["app", "-local-script-harness"]).runsLocalScriptHarness == false)
    }

    @Test func guestIntentTraversesTransportAndBothRecipientsConvergeAtVersionTwo() async throws {
        let pair = makePair()
        try await pair.host.createRoom()
        try await pair.guest.joinRoom()
        try await eventually { await pair.host.playerIDs.count == 2 }
        try await pair.host.setReady(true)
        try await pair.guest.setReady(true)
        try await eventually { await pair.host.readyPlayerIDs.count == 2 }
        try await pair.host.startGame()
        try await eventually { await pair.guest.snapshot != nil }

        let hostCard = try #require(await pair.host.snapshot?.players.first(where: { $0.id == hostID })?.hand?.first)
        try await pair.host.pass(discardCardID: hostCard)
        try await eventually {
            let hostVersion = await pair.host.snapshot?.authoritativeVersion
            let guestVersion = await pair.guest.snapshot?.authoritativeVersion
            return hostVersion == .init(rawValue: 1) && guestVersion == .init(rawValue: 1)
        }
        #expect(await pair.guest.snapshot?.activePlayerID == guestID)
        let messagesBeforeGuestIntent = await pair.host.processedMessageCount
        let guestCard = try #require(await pair.guest.snapshot?.players.first(where: { $0.id == guestID })?.hand?.first)
        try await pair.guest.pass(discardCardID: guestCard)
        try await eventually {
            let hostVersion = await pair.host.snapshot?.authoritativeVersion
            let guestVersion = await pair.guest.snapshot?.authoritativeVersion
            return hostVersion == .init(rawValue: 2) && guestVersion == .init(rawValue: 2)
        }

        let hostSnapshot = try #require(await pair.host.snapshot)
        let guestSnapshot = try #require(await pair.guest.snapshot)
        #expect(await pair.host.processedMessageCount == messagesBeforeGuestIntent + 1)
        #expect(hostSnapshot.players.allSatisfy { $0.id == hostID ? $0.hand != nil : $0.hand == nil })
        #expect(guestSnapshot.players.allSatisfy { $0.id == guestID ? $0.hand != nil : $0.hand == nil })
        #expect(publicChecksum(hostSnapshot) == publicChecksum(guestSnapshot))
    }

    @Test func fifthSeatIsRejected() async throws {
        let hub = LoopbackTransportHub()
        let hostTransport = hub.makeTransport(peerID: .init(rawValue: "host"))
        let host = coordinator(id: "host", token: "t-host", transport: hostTransport)
        try await host.createRoom()
        for index in 1...4 {
            let guest = coordinator(
                id: "g\(index)", token: "t-g\(index)",
                transport: hub.makeTransport(peerID: .init(rawValue: "g\(index)"))
            )
            if index < 4 {
                try await guest.joinRoom()
            } else {
                await #expect(throws: SessionCoordinator.Error.roomFull) { try await guest.joinRoom() }
            }
        }
        #expect(await host.playerIDs.count == 4)
    }

    @Test(arguments: [(2, "rules-v1"), (1, "rules-v2")])
    func compatibilityMismatchIsRejectedBeforeLobbyMutation(protocolVersion: Int, rulesetVersion: String) async throws {
        let hub = LoopbackTransportHub()
        let host = coordinator(id: "host", token: "t-host", transport: hub.makeTransport(peerID: .init(rawValue: "host")))
        let guest = SessionCoordinator(
            configuration: .init(protocolVersion: protocolVersion, rulesetVersion: rulesetVersion, roomID: room,
                                 playerID: guestID, reconnectToken: .init(rawValue: "t-guest"), hostPlayerID: hostID),
            transport: hub.makeTransport(peerID: .init(rawValue: "guest")),
            rulesMode: .fixtureOnlyLegacy
        )
        try await host.createRoom()
        await #expect(throws: SessionCoordinator.Error.incompatiblePeer) { try await guest.joinRoom() }
        #expect(await host.playerIDs == [hostID])
    }

    @Test func verifiedCatalogVersionMustMatchTheSessionConfigurationBeforeHosting() async throws {
        let catalog = try GameCore.GameDataLoader.loadBundledFixtureCatalog()
        let hub = LoopbackTransportHub()
        let host = SessionCoordinator(
            configuration: .init(
                protocolVersion: 2,
                rulesetVersion: "wrong-ruleset",
                roomID: room,
                playerID: hostID,
                reconnectToken: .init(rawValue: "wrong-version-host"),
                hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: hostID),
            rulesMode: .verified(catalog)
        )

        await #expect(throws: SessionCoordinator.Error.dataUnavailable) {
            try await host.createRoom()
        }
        #expect(await host.playerIDs.isEmpty)
        #expect(await host.isProcessing == false)
    }

    @Test func reconnectTokenIsBoundToRoomAndPlayer() async throws {
        let hub = LoopbackTransportHub()
        let host = coordinator(id: "host", token: "t-host", transport: hub.makeTransport(peerID: .init(rawValue: "host")))
        let original = coordinator(id: "guest", token: "right", transport: hub.makeTransport(peerID: .init(rawValue: "guest")))
        try await host.createRoom()
        try await original.joinRoom()
        await original.disconnect()
        let impostor = coordinator(id: "guest", token: "wrong", transport: hub.makeTransport(peerID: .init(rawValue: "guest-reconnect")))
        await #expect(throws: SessionCoordinator.Error.reconnectTokenMismatch) { try await impostor.joinRoom() }
        #expect(await host.playerIDs.count == 2)
    }

    @Test func existingSeatReconnectDoesNotRewriteTokenOrEvictRosterWhenTokenStoreBecomesUnavailable() async throws {
        let hub = LoopbackTransportHub()
        let adapter = ToggleFailingSecureItemAdapter()
        let tokenStore = RoomTokenStore(adapter: adapter)
        let host = coordinator(
            id: "host", token: "t-host", transport: hub.makeTransport(peerID: hostID),
            tokenStore: tokenStore
        )
        let original = coordinator(
            id: "guest", token: "right", transport: hub.makeTransport(peerID: guestID)
        )

        try await host.createRoom()
        try await original.joinRoom()
        try await eventually { Set(await host.playerIDs) == [self.hostID, self.guestID] }
        let writesBeforeReconnect = adapter.writeCount

        await original.disconnect()
        try await eventually { await host.connectedPlayerIDs == [self.hostID] }
        adapter.setFailWrites(true)

        let reconnected = coordinator(
            id: "guest", token: "right",
            transport: hub.makeTransport(peerID: .init(rawValue: "guest-reconnected"))
        )
        try await reconnected.joinRoom()
        try await eventually { await host.connectedPlayerIDs == [self.hostID, self.guestID] }

        #expect(Set(await host.playerIDs) == [hostID, guestID])
        #expect(adapter.writeCount == writesBeforeReconnect)
    }

    @Test func pendingNewSeatCannotEnterRosterOrStartGameBeforeTokenPersistenceCommits() async throws {
        let hub = LoopbackTransportHub()
        let secondGuestID = GameCore.PlayerID(rawValue: "guest-two")
        let adapter = ToggleFailingSecureItemAdapter()
        let tokenStore = RoomTokenStore(adapter: adapter)
        let host = coordinator(
            id: "host", token: "t-host", transport: hub.makeTransport(peerID: hostID),
            tokenStore: tokenStore
        )
        let firstGuest = coordinator(
            id: "guest", token: "t-guest", transport: hub.makeTransport(peerID: guestID)
        )
        let secondGuest = coordinator(
            id: secondGuestID.rawValue, token: "t-guest-two",
            transport: hub.makeTransport(peerID: secondGuestID)
        )

        try await host.createRoom()
        try await firstGuest.joinRoom()
        try await host.setReady(true)
        try await firstGuest.setReady(true)
        try await eventually { Set(await host.readyPlayerIDs) == [self.hostID, self.guestID] }

        adapter.blockNextWrite(thenFail: true)
        let pendingJoin = Task { try await secondGuest.joinRoom() }
        #expect(adapter.waitUntilWriteBlocks())

        #expect(Set(await host.playerIDs) == [hostID, guestID])
        #expect(await host.connectedPlayerIDs == [hostID, guestID])
        await #expect(throws: SessionCoordinator.Error.notAllPlayersReady) {
            try await host.startGame()
        }
        #expect(await host.snapshot == nil)

        adapter.releaseBlockedWrite()
        await #expect(throws: SessionCoordinator.Error.persistenceUnavailable) {
            try await pendingJoin.value
        }
        try await eventually {
            let players = Set(await host.playerIDs)
            let ready = Set(await host.readyPlayerIDs)
            let connected = await host.connectedPlayerIDs
            return players == [self.hostID, self.guestID]
                && ready == [self.hostID, self.guestID]
                && connected == [self.hostID, self.guestID]
        }

        try await host.startGame()
        #expect(await host.snapshot != nil)
    }

    @Test func pendingNewSeatBecomesVisibleOnlyAfterTokenPersistenceCommits() async throws {
        let hub = LoopbackTransportHub()
        let adapter = ToggleFailingSecureItemAdapter()
        let tokenStore = RoomTokenStore(adapter: adapter)
        let host = coordinator(
            id: "host", token: "t-host", transport: hub.makeTransport(peerID: hostID),
            tokenStore: tokenStore
        )
        let guest = coordinator(
            id: "guest", token: "t-guest", transport: hub.makeTransport(peerID: guestID)
        )

        try await host.createRoom()
        adapter.blockNextWrite(thenFail: false)
        let pendingJoin = Task { try await guest.joinRoom() }
        #expect(adapter.waitUntilWriteBlocks())

        #expect(await host.playerIDs == [hostID])
        #expect(await host.connectedPlayerIDs == [hostID])

        adapter.releaseBlockedWrite()
        try await pendingJoin.value
        try await eventually {
            let players = Set(await host.playerIDs)
            let connected = await host.connectedPlayerIDs
            return players == [self.hostID, self.guestID]
                && connected == [self.hostID, self.guestID]
        }
    }

    @Test func disconnectDuringSuccessfulSeatPersistenceCommitsAnOfflineReconnectableSeat() async throws {
        let hub = LoopbackTransportHub()
        let adapter = ToggleFailingSecureItemAdapter()
        let tokenStore = RoomTokenStore(adapter: adapter)
        let host = coordinator(
            id: "host", token: "t-host", transport: hub.makeTransport(peerID: hostID),
            tokenStore: tokenStore
        )
        let firstAttempt = coordinator(
            id: "guest", token: "t-guest", transport: hub.makeTransport(peerID: guestID)
        )

        try await host.createRoom()
        adapter.blockNextWrite(thenFail: false)
        let pendingJoin = Task { try await firstAttempt.joinRoom() }
        #expect(adapter.waitUntilWriteBlocks())

        await firstAttempt.disconnect()
        adapter.releaseBlockedWrite()
        try await eventually {
            let players = Set(await host.playerIDs)
            let connected = await host.connectedPlayerIDs
            return players == [self.hostID, self.guestID]
                && connected == [self.hostID]
        }
        pendingJoin.cancel()
        _ = await pendingJoin.result

        let reconnected = coordinator(
            id: "guest", token: "t-guest",
            transport: hub.makeTransport(peerID: .init(rawValue: "guest-reconnected-after-persist"))
        )
        try await reconnected.joinRoom()
        try await eventually {
            let players = Set(await host.playerIDs)
            let connected = await host.connectedPlayerIDs
            return players == [self.hostID, self.guestID]
                && connected == [self.hostID, self.guestID]
        }
    }

    @Test func readyMessageIsBoundToTheAuthenticatedTransportPeer() async throws {
        let hub = LoopbackTransportHub()
        let hostTransport = hub.makeTransport(peerID: hostID)
        let guestTransport = hub.makeTransport(peerID: guestID)
        let attackerTransport = hub.makeTransport(peerID: .init(rawValue: "attacker"))
        let host = coordinator(id: "host", token: "t-host", transport: hostTransport)
        let guest = coordinator(id: "guest", token: "t-guest", transport: guestTransport)
        try await host.createRoom()
        try await guest.joinRoom()
        try await attackerTransport.connect(to: hostID)
        let spoof = SessionProtocol.SessionEnvelope(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            messageID: .init(rawValue: "spoof-ready"), senderID: guestID, recipientID: hostID,
            authoritativeVersion: .init(rawValue: 0), payload: .ready(true)
        )
        try await attackerTransport.send(JSONEncoder().encode(spoof), to: hostID)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await host.readyPlayerIDs == [])
    }

    @Test func wrongRoomHelloFailsImmediatelyWithoutMutatingHostLobby() async throws {
        let hub = LoopbackTransportHub()
        let host = coordinator(id: "host", token: "t-host", transport: hub.makeTransport(peerID: hostID))
        let wrongRoomGuest = SessionCoordinator(
            configuration: .init(protocolVersion: 1, rulesetVersion: "rules-v1", roomID: .init(rawValue: "WRONG"),
                                 playerID: guestID, reconnectToken: .init(rawValue: "t-guest"), hostPlayerID: hostID),
            transport: hub.makeTransport(peerID: guestID),
            rulesMode: .fixtureOnlyLegacy
        )
        try await host.createRoom()
        let clock = ContinuousClock(); let started = clock.now
        await #expect(throws: SessionCoordinator.Error.roomMismatch) { try await wrongRoomGuest.joinRoom() }
        #expect(started.duration(to: clock.now) < .seconds(1))
        #expect(await host.playerIDs == [hostID])
    }

    @Test func validRoomHelloAddressedAwayFromHostCannotAdmitOrConsumeReplayScope() async throws {
        let hub = LoopbackTransportHub()
        let host = coordinator(id: "host", token: "t-host", transport: hub.makeTransport(peerID: hostID))
        let attacker = hub.makeTransport(peerID: .init(rawValue: "attacker"))
        try await host.createRoom(); try await attacker.connect(to: hostID)
        let envelope = SessionProtocol.SessionEnvelope(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            messageID: .init(rawValue: "misaddressed-hello"), senderID: guestID,
            recipientID: .init(rawValue: "someone-else"), authoritativeVersion: .init(rawValue: 0),
            payload: .hello(reconnectToken: .init(rawValue: "t-guest"))
        )
        try await attacker.send(JSONEncoder().encode(envelope), to: hostID)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await host.playerIDs == [hostID])
        #expect(await host.replayScopeCount == 0)
        #expect(await host.processedMessageCount == 0)
    }

    @Test func forgedStaleSkippedAndNonHostClientEventsCannotReplaceGuestSnapshot() async throws {
        let pair = makePair()
        try await pair.host.createRoom(); try await pair.guest.joinRoom()
        try await eventually { await pair.host.playerIDs.count == 2 }
        try await pair.host.setReady(true); try await pair.guest.setReady(true)
        try await eventually { await pair.host.readyPlayerIDs.count == 2 }
        try await pair.host.startGame(); try await eventually { await pair.guest.snapshot != nil }
        let original = try #require(await pair.guest.snapshot)
        let valid = makeClientEvent(from: original, actor: hostID, version: 1, actionNumber: 1)
        let malformed: [GameCore.ClientEvent] = [
            makeClientEvent(from: original, actor: hostID, version: 1, actionNumber: 1,
                            eventRoomID: .init(rawValue: "FORGED")),
            makeClientEvent(from: original, actor: hostID, version: 2, actionNumber: 1),
            makeClientEvent(from: original, actor: hostID, version: 1, previousVersion: 9, actionNumber: 1),
            makeClientEvent(from: original, actor: hostID, version: 1, actionNumber: 3),
            makeClientEvent(from: original, actor: .init(rawValue: "unknown"), version: 1, actionNumber: 1),
            clientEvent(valid, players: [valid.snapshot.players[0], valid.snapshot.players[0]]),
            clientEvent(valid, players: valid.snapshot.players.map {
                .init(id: $0.id, handCount: $0.handCount, hand: ["leaked"])
            }),
        ]
        for (index, event) in malformed.enumerated() {
            try await pair.hostTransport.send(try encodedClientEvent(event, messageID: "forged-\(index)"), to: guestID)
        }
        let hubAttacker = pair.hub.makeTransport(peerID: .init(rawValue: "attacker"))
        try await hubAttacker.connect(to: guestID)
        try await hubAttacker.send(try encodedClientEvent(valid, messageID: "wrong-peer"), to: guestID)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await pair.guest.snapshot == original)
    }

    @Test func duplicateMessageIDIsSuppressed() async throws {
        let pair = makePair()
        try await pair.host.createRoom()
        try await pair.guest.joinRoom()
        try await eventually { await pair.host.playerIDs.count == 2 }
        let envelope = SessionProtocol.SessionEnvelope(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            messageID: .init(rawValue: "same"), senderID: guestID, recipientID: hostID,
            authoritativeVersion: .init(rawValue: 0), payload: .ready(true)
        )
        let data = try JSONEncoder().encode(envelope)
        try await pair.guestTransport.send(data, to: .init(rawValue: "host"))
        try await pair.guestTransport.send(data, to: .init(rawValue: "host"))
        try await eventually { await pair.host.processedMessageCount == 2 } // hello + one ready
        #expect(await pair.host.readyPlayerIDs == [guestID])
    }

    @Test func oversizedMessageIDIsDroppedBeforeReplayOrRecoveryMutation() {
        let oversized = SessionProtocol.MessageID(rawValue: String(repeating: "x", count: 129))
        var recoveryCache = InvalidRecoveryReplayCache(capacity: 4)
        let inserted = recoveryCache.insert(oversized, authenticatedHostID: hostID)
        #expect(!oversized.isValid)
        #expect(!inserted)
        #expect(recoveryCache.count == 0)
    }

    @Test func forgedLobbyStateDoesNotConsumeReplayIDBeforeValidHostState() async throws {
        let pair = makePair()
        try await pair.host.createRoom(); try await pair.guest.joinRoom()
        try await eventually { await pair.guest.playerIDs.count == 2 }
        let originalCount = await pair.guest.processedMessageCount
        let id = SessionProtocol.MessageID(rawValue: "shared-lobby")
        let validPayload = SessionProtocol.Payload.lobbyState(.init(playerIDs: [hostID, guestID], readyPlayerIDs: [hostID]))
        let forged: [SessionProtocol.SessionEnvelope] = [
            .init(protocolVersion: 2, rulesetVersion: "rules-v1", roomID: room, messageID: id,
                  senderID: hostID, recipientID: guestID, authoritativeVersion: .init(rawValue: 0), payload: validPayload),
            .init(protocolVersion: 1, rulesetVersion: "wrong", roomID: room, messageID: id,
                  senderID: hostID, recipientID: guestID, authoritativeVersion: .init(rawValue: 0), payload: validPayload),
            .init(protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room, messageID: id,
                  senderID: hostID, recipientID: guestID, authoritativeVersion: .init(rawValue: 0),
                  payload: .lobbyState(.init(playerIDs: [hostID, hostID], readyPlayerIDs: [])))
        ]
        for envelope in forged { try await pair.hostTransport.send(JSONEncoder().encode(envelope), to: guestID) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(await pair.guest.processedMessageCount == originalCount)
        let valid = SessionProtocol.SessionEnvelope(protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            messageID: id, senderID: hostID, recipientID: guestID, authoritativeVersion: .init(rawValue: 0), payload: validPayload)
        try await pair.hostTransport.send(JSONEncoder().encode(valid), to: guestID)
        try await eventually { await pair.guest.readyPlayerIDs == [hostID] }
        #expect(await pair.guest.processedMessageCount == originalCount + 1)
    }

    @Test func unauthenticatedPreplayDoesNotSuppressLegitimateMessageWithSameID() async throws {
        let pair = makePair()
        let attacker = pair.hub.makeTransport(peerID: .init(rawValue: "attacker-preplay"))
        try await pair.host.createRoom(); try await pair.guest.joinRoom(); try await attacker.connect(to: hostID)
        let data = try encodedReady(messageID: "shared-id", value: true)
        try await attacker.send(data, to: hostID)
        try await pair.guestTransport.send(data, to: hostID)
        try await eventually { await pair.host.readyPlayerIDs == [guestID] }
        #expect(await pair.host.processedMessageCount == 2) // authenticated hello + ready
    }

    @Test func replayCacheEvictsOldestAfterOneHundredTwentyEightAuthenticatedMessages() async throws {
        let pair = makePair()
        try await pair.host.createRoom(); try await pair.guest.joinRoom()
        for index in 0...128 {
            try await pair.guestTransport.send(try encodedReady(messageID: "ready-\(index)", value: true), to: hostID)
        }
        try await eventually { await pair.host.processedMessageCount == 130 } // hello + 129 ready messages
        try await pair.guestTransport.send(try encodedReady(messageID: "ready-128", value: false), to: hostID)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await pair.host.readyPlayerIDs == [guestID])
        try await pair.guestTransport.send(try encodedReady(messageID: "ready-0", value: false), to: hostID)
        try await eventually { await pair.host.readyPlayerIDs == [] }
        #expect(await pair.host.processedMessageCount == 131)
    }

    @Test func forgedOuterSenderAndRecipientDoNotPoisonLegitimateIntentReplay() async throws {
        let pair = makePair()
        try await pair.host.createRoom(); try await pair.guest.joinRoom()
        try await eventually { await pair.host.playerIDs.count == 2 }
        try await pair.host.setReady(true); try await pair.guest.setReady(true)
        try await eventually { await pair.host.readyPlayerIDs.count == 2 }
        try await pair.host.startGame(); try await eventually { await pair.guest.snapshot != nil }
        let hostCard = try #require(await pair.host.snapshot?.players.first(where: { $0.id == hostID })?.hand?.first)
        try await pair.host.pass(discardCardID: hostCard)
        try await eventually { await pair.guest.snapshot?.authoritativeVersion == .init(rawValue: 1) }
        let guestCard = try #require(await pair.guest.snapshot?.players.first(where: { $0.id == guestID })?.hand?.first)
        let intent = GameCore.PlayerIntent(protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            senderID: guestID, reconnectToken: .init(rawValue: "t-guest"), baseVersion: .init(rawValue: 1),
            payload: .pass(.init(cardID: guestCard)))
        let forged = SessionProtocol.SessionEnvelope(protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            messageID: .init(rawValue: "intent-shared"), senderID: .init(rawValue: "attacker"), recipientID: hostID,
            authoritativeVersion: .init(rawValue: 1), payload: .intent(intent))
        let legitimate = SessionProtocol.SessionEnvelope(protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            messageID: .init(rawValue: "intent-shared"), senderID: guestID, recipientID: hostID,
            authoritativeVersion: .init(rawValue: 1), payload: .intent(intent))
        try await pair.guestTransport.send(JSONEncoder().encode(forged), to: hostID)
        try await pair.guestTransport.send(JSONEncoder().encode(legitimate), to: hostID)
        try await eventually { await pair.host.snapshot?.authoritativeVersion == .init(rawValue: 2) }
        #expect(await pair.host.replayScopeCount <= 4)
    }

    @Test func varyingForgedOuterSendersCannotGrowReplayScopes() async throws {
        let pair = makePair()
        try await pair.host.createRoom(); try await pair.guest.joinRoom()
        for index in 0..<256 {
            let envelope = SessionProtocol.SessionEnvelope(protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
                messageID: .init(rawValue: "forged-scope-\(index)"), senderID: .init(rawValue: "attacker-\(index)"),
                recipientID: hostID, authoritativeVersion: .init(rawValue: 0), payload: .ready(true))
            try await pair.guestTransport.send(JSONEncoder().encode(envelope), to: hostID)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await pair.host.replayScopeCount <= 4)
        #expect(await pair.host.readyPlayerIDs == [])
    }

    @Test func partialFanoutAdvancesHostAndHealthyGuestWhileMarkingFailedSeatForRecovery() async throws {
        let hub = LoopbackTransportHub()
        let rawHost = hub.makeTransport(peerID: hostID)
        let control = SendFailureControl()
        let hostTransport = SelectiveFailingTransport(base: rawHost, control: control)
        let guestOneID = GameCore.PlayerID(rawValue: "g1")
        let guestTwoID = GameCore.PlayerID(rawValue: "g2")
        let host = coordinator(id: "host", token: "t-host", transport: hostTransport)
        let guestOne = coordinator(id: "g1", token: "t-g1", transport: hub.makeTransport(peerID: guestOneID))
        let guestTwo = coordinator(id: "g2", token: "t-g2", transport: hub.makeTransport(peerID: guestTwoID))
        try await host.createRoom(); try await guestOne.joinRoom(); try await guestTwo.joinRoom()
        try await eventually { await host.playerIDs.count == 3 }
        try await host.setReady(true); try await guestOne.setReady(true); try await guestTwo.setReady(true)
        try await eventually { await host.readyPlayerIDs.count == 3 }
        try await host.startGame(); try await eventually { await guestTwo.snapshot != nil }
        await control.failSends(to: guestOneID)
        let card = try #require(await host.snapshot?.players.first(where: { $0.id == hostID })?.hand?.first)
        try await host.pass(discardCardID: card)
        try await eventually { await guestTwo.snapshot?.authoritativeVersion == .init(rawValue: 1) }
        #expect(await host.snapshot?.authoritativeVersion == .init(rawValue: 1))
        #expect(await guestOne.snapshot?.authoritativeVersion == .init(rawValue: 0))
        #expect(await host.peersNeedingRecovery == [guestOneID])
        #expect(await host.lastDeliveryError != nil)
    }

    @Test func successfulRecoveryClearsTheDeliveryError() async throws {
        let hub = LoopbackTransportHub()
        let rawHost = hub.makeTransport(peerID: hostID)
        let control = SendFailureControl()
        let host = coordinator(id: "host", token: "t-host", transport: SelectiveFailingTransport(base: rawHost, control: control))
        let guest = coordinator(id: "guest", token: "t-guest", transport: hub.makeTransport(peerID: guestID))
        try await host.createRoom(); try await guest.joinRoom()
        try await eventually { await host.playerIDs.count == 2 }
        try await host.setReady(true); try await guest.setReady(true)
        try await eventually { await host.readyPlayerIDs.count == 2 }
        try await host.startGame(); try await eventually { await guest.snapshot != nil }
        await control.failSends(to: guestID)
        let card = try #require(await host.snapshot?.players.first(where: { $0.id == hostID })?.hand?.first)
        try await host.pass(discardCardID: card)
        try await eventually { await host.peersNeedingRecovery == [guestID] }
        #expect(await host.lastDeliveryError != nil)

        await control.restoreSends(to: guestID)
        await guest.disconnect()
        let reconnected = coordinator(id: "guest", token: "t-guest", transport: hub.makeTransport(peerID: guestID))
        try await reconnected.joinRoom()
        try await eventually { await host.peersNeedingRecovery.isEmpty }
        #expect(await host.lastDeliveryError == nil)
    }

    @Test func reconnectAfterPartialFanoutReceivesLatestSnapshotAndClearsRecovery() async throws {
        let catalog = try verifiedCatalog()
        let hub = LoopbackTransportHub()
        let rawHost = hub.makeTransport(peerID: hostID)
        let control = SendFailureControl()
        let host = realCoordinator(
            id: hostID, token: "t-host",
            transport: SelectiveFailingTransport(base: rawHost, control: control), catalog: catalog
        )
        let guestID = GameCore.PlayerID(rawValue: "g1")
        let guest = realCoordinator(
            id: guestID, token: "t-g1", transport: hub.makeTransport(peerID: guestID), catalog: catalog
        )
        try await host.createRoom(); try await guest.joinRoom()
        try await host.setReady(true); try await guest.setReady(true)
        try await eventually { await host.readyPlayerIDs.count == 2 }
        try await host.startGame(); try await eventually { await guest.snapshot != nil }
        let guestVersionZero = try #require(await guest.snapshot)
        await control.failSends(to: guestID)
        let actor = try #require(await host.snapshot?.activePlayerID)
        let actorCoordinator = actor == hostID ? host : guest
        let card = try #require(await actorCoordinator.snapshot?.players.first(where: { $0.id == actor })?.hand?.first)
        try await actorCoordinator.pass(discardCardID: card)
        try await eventually { await host.peersNeedingRecovery == [guestID] }
        await guest.disconnect(); await control.restoreSends(to: guestID); await control.clearRecorded()
        let reconnected = SessionCoordinator(
            configuration: .init(
                protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion,
                roomID: room, playerID: guestID, reconnectToken: .init(rawValue: "t-g1"),
                hostPlayerID: hostID
            ),
            restoredGuest: .init(
                snapshot: guestVersionZero, eventWindow: [],
                tokenReference: .init(roomID: room, playerID: guestID), hostPlayerID: hostID
            ),
            transport: hub.makeTransport(peerID: .init(rawValue: "g1-new")),
            rulesMode: .verified(catalog)
        )
        try await reconnected.joinRoom()
        try await eventually { await reconnected.snapshot?.authoritativeVersion == .init(rawValue: 1) }
        #expect(await host.peersNeedingRecovery == [])
        let recoveryPayloads = await control.recordedPayloads()
        #expect(recoveryPayloads.contains { if case .clientEvent = $0 { true } else { false } })
        #expect(!recoveryPayloads.contains { if case .viewSnapshot = $0 { true } else { false } })
    }

    @Test func initialSnapshotFanoutFailureKeepsHostPlayableAndGuestCanCatchUp() async throws {
        let catalog = try verifiedCatalog()
        let hub = LoopbackTransportHub()
        let control = SendFailureControl()
        let host = realCoordinator(
            id: hostID, token: "t-host",
            transport: SelectiveFailingTransport(base: hub.makeTransport(peerID: hostID), control: control),
            catalog: catalog
        )
        let guest = realCoordinator(
            id: guestID, token: "t-guest", transport: hub.makeTransport(peerID: guestID), catalog: catalog
        )
        try await host.createRoom(); try await guest.joinRoom()
        try await host.setReady(true); try await guest.setReady(true)
        try await eventually { await host.readyPlayerIDs.count == 2 }
        await control.failSends(to: guestID)

        try await host.startGame()

        #expect(await host.snapshot != nil)
        #expect(await host.peersNeedingRecovery == [guestID])
        #expect(await guest.snapshot == nil)

        await guest.disconnect()
        await control.restoreSends(to: guestID)
        let reconnected = realCoordinator(
            id: guestID, token: "t-guest",
            transport: hub.makeTransport(peerID: .init(rawValue: "guest-reconnected")), catalog: catalog
        )
        try await reconnected.joinRoom()
        try await eventually { await reconnected.snapshot != nil }
        let recoveredVersion = await reconnected.snapshot?.authoritativeVersion
        let hostVersion = await host.snapshot?.authoritativeVersion
        #expect(recoveredVersion == hostVersion)
        #expect(await host.peersNeedingRecovery.isEmpty)
    }

    @Test func recoverySnapshotCannotRollbackGuestVersionOrActionNumber() async throws {
        let pair = makePair()
        try await pair.host.createRoom(); try await pair.guest.joinRoom()
        try await eventually { await pair.host.playerIDs.count == 2 }
        try await pair.host.setReady(true); try await pair.guest.setReady(true)
        try await eventually { await pair.host.readyPlayerIDs.count == 2 }
        try await pair.host.startGame(); try await eventually { await pair.guest.snapshot != nil }
        let versionZero = try #require(await pair.guest.snapshot)
        let card = try #require(await pair.host.snapshot?.players.first(where: { $0.id == hostID })?.hand?.first)
        try await pair.host.pass(discardCardID: card)
        try await eventually { await pair.guest.snapshot?.authoritativeVersion == .init(rawValue: 1) }
        let versionOne = try #require(await pair.guest.snapshot)
        try await pair.hostTransport.send(try encodedSnapshot(versionZero, messageID: "rollback-v0"), to: guestID)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await pair.guest.snapshot == versionOne)
    }

    @Test func recoverySnapshotRejectsMismatchedOuterProtocolBeforePayloadValidation() async throws {
        let pair = makePair()
        try await pair.host.createRoom(); try await pair.guest.joinRoom()
        try await eventually { await pair.host.playerIDs.count == 2 }
        try await pair.host.setReady(true); try await pair.guest.setReady(true)
        try await eventually { await pair.host.readyPlayerIDs.count == 2 }
        try await pair.host.startGame(); try await eventually { await pair.guest.snapshot != nil }
        let versionZero = try #require(await pair.guest.snapshot)
        let forged = replacing(versionZero, version: 1, actionNumber: 1)
        try await pair.hostTransport.send(
            try encodedSnapshot(forged, messageID: "wrong-protocol", protocolVersion: 2),
            to: guestID
        )
        try await Task.sleep(for: .milliseconds(50))
        #expect(await pair.guest.snapshot == versionZero)
    }

    private func makePair() -> (host: SessionCoordinator, guest: SessionCoordinator, hostTransport: LoopbackTransport,
                                guestTransport: LoopbackTransport, hub: LoopbackTransportHub) {
        let hub = LoopbackTransportHub()
        let hostTransport = hub.makeTransport(peerID: hostID)
        let guestTransport = hub.makeTransport(peerID: guestID)
        return (coordinator(id: "host", token: "t-host", transport: hostTransport),
                coordinator(id: "guest", token: "t-guest", transport: guestTransport), hostTransport, guestTransport, hub)
    }

    private func coordinator(
        id: String,
        token: String,
        transport: some Transport,
        tokenStore: RoomTokenStore? = nil
    ) -> SessionCoordinator {
        SessionCoordinator(configuration: .init(protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: .init(rawValue: id), reconnectToken: .init(rawValue: token), hostPlayerID: hostID),
            transport: transport, tokenStore: tokenStore, rulesMode: .fixtureOnlyLegacy)
    }

    private func realCoordinator(
        id: GameCore.PlayerID, token: String, transport: some Transport,
        catalog: GameCore.VerifiedGameDataCatalog
    ) -> SessionCoordinator {
        SessionCoordinator(
            configuration: .init(
                protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion,
                roomID: room, playerID: id, reconnectToken: .init(rawValue: token), hostPlayerID: hostID
            ),
            transport: transport, rulesMode: .verified(catalog)
        )
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
                id: "session-build-network", url: "https://example.invalid/rules",
                component: "rules", version: "2018.11", page: "all",
                transcriber: "test", transcribedOn: "2026-08-18",
                checker: "independent-test", checkedOn: "2026-08-18"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: JSONEncoder().encode(manifest), files: files
        )
    }

    private func eventually(timeout: Duration = .seconds(2), _ condition: @escaping @Sendable () async -> Bool) async throws {
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw TestTimeout()
    }

    private func publicChecksum(_ snapshot: GameCore.ViewSnapshot) -> String {
        snapshot.players.map { "\($0.id.rawValue):\($0.handCount)" }.joined(separator: "|")
            + "|\(snapshot.activePlayerID.rawValue)|\(snapshot.turn)|\(snapshot.actionNumber)|\(snapshot.authoritativeVersion.rawValue)|\(snapshot.discardPile.joined(separator: ","))"
    }

    private func makeClientEvent(from snapshot: GameCore.ViewSnapshot, actor: GameCore.PlayerID, version: Int,
                                 previousVersion: Int = 0, actionNumber: Int,
                                 eventRoomID: GameCore.RoomID? = nil) -> GameCore.ClientEvent {
        let nextSnapshot = replacing(snapshot, version: version, actionNumber: actionNumber)
        return .init(event: .init(roomID: eventRoomID ?? room, actor: actor, previousVersion: .init(rawValue: previousVersion),
                                  version: .init(rawValue: version), actionNumber: actionNumber,
                                  payload: .passed(discardedCardID: "x")), snapshot: nextSnapshot)
    }

    private func clientEvent(_ event: GameCore.ClientEvent, players: [GameCore.VisiblePlayer]) -> GameCore.ClientEvent {
        .init(event: event.event, snapshot: replacing(event.snapshot, players: players))
    }

    private func replacing(_ snapshot: GameCore.ViewSnapshot, players: [GameCore.VisiblePlayer]? = nil,
                           version: Int? = nil, actionNumber: Int? = nil) -> GameCore.ViewSnapshot {
        let players = players ?? snapshot.players
        let version = GameCore.AuthoritativeVersion(rawValue: version ?? snapshot.authoritativeVersion.rawValue)
        let actionNumber = actionNumber ?? snapshot.actionNumber
        return .init(roomID: snapshot.roomID, recipient: snapshot.recipient, players: players,
                     activePlayerID: snapshot.activePlayerID, turn: snapshot.turn, actionNumber: actionNumber,
                     authoritativeVersion: version, discardPile: snapshot.discardPile,
                     checksum: try! GameCore.snapshotChecksum(roomID: snapshot.roomID, recipient: snapshot.recipient,
                         players: players, activePlayerID: snapshot.activePlayerID, turn: snapshot.turn,
                         actionNumber: actionNumber, authoritativeVersion: version, discardPile: snapshot.discardPile))
    }

    private func encodedClientEvent(_ event: GameCore.ClientEvent, messageID: String) throws -> Data {
        try JSONEncoder().encode(SessionProtocol.SessionEnvelope(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room, messageID: .init(rawValue: messageID),
            senderID: hostID, recipientID: guestID, authoritativeVersion: event.event.version,
            payload: .clientEvent(event)
        ))
    }

    private func encodedReady(messageID: String, value: Bool) throws -> Data {
        try JSONEncoder().encode(SessionProtocol.SessionEnvelope(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room, messageID: .init(rawValue: messageID),
            senderID: guestID, recipientID: hostID, authoritativeVersion: .init(rawValue: 0), payload: .ready(value)
        ))
    }

    private func encodedSnapshot(
        _ snapshot: GameCore.ViewSnapshot,
        messageID: String,
        protocolVersion: Int = 1
    ) throws -> Data {
        try JSONEncoder().encode(SessionProtocol.SessionEnvelope(
            protocolVersion: protocolVersion, rulesetVersion: "rules-v1", roomID: room, messageID: .init(rawValue: messageID),
            senderID: hostID, recipientID: guestID, authoritativeVersion: snapshot.authoritativeVersion,
            payload: .viewSnapshot(snapshot)
        ))
    }
}

private actor SendFailureControl {
    private var failedPeers: Set<GameCore.PlayerID> = []
    private var payloads: [SessionProtocol.Payload] = []
    func failSends(to peer: GameCore.PlayerID) { failedPeers.insert(peer) }
    func restoreSends(to peer: GameCore.PlayerID) { failedPeers.remove(peer) }
    func shouldFail(_ peer: GameCore.PlayerID) -> Bool { failedPeers.contains(peer) }
    func record(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(SessionProtocol.SessionEnvelope.self, from: data) else { return }
        payloads.append(envelope.payload)
    }
    func clearRecorded() { payloads = [] }
    func recordedPayloads() -> [SessionProtocol.Payload] { payloads }
}

private actor SelectiveFailingTransport: Transport {
    nonisolated let events: AsyncStream<TransportEvent>
    private let base: LoopbackTransport
    private let control: SendFailureControl

    init(base: LoopbackTransport, control: SendFailureControl) {
        self.base = base; self.control = control; self.events = base.events
    }

    func startHosting(roomID: GameCore.RoomID, port: UInt16?) async throws { try await base.startHosting(roomID: roomID, port: port) }
    func browse() async throws { try await base.browse() }
    func connect(to peer: GameCore.PlayerID) async throws { try await base.connect(to: peer) }
    func send(_ data: Data, to peer: GameCore.PlayerID) async throws {
        if await control.shouldFail(peer) { throw TransportError.connectionFailed }
        await control.record(data)
        try await base.send(data, to: peer)
    }
    func disconnect() async { await base.disconnect() }
}

private final class ToggleFailingSecureItemAdapter: SecureItemAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private let blockedWriteEntered = DispatchSemaphore(value: 0)
    private let blockedWriteRelease = DispatchSemaphore(value: 0)
    private var storage: [String: Data] = [:]
    private var shouldFailWrites = false
    private var blockedWriteShouldFail: Bool?
    private var writes = 0

    var writeCount: Int { lock.withLock { writes } }

    func setFailWrites(_ value: Bool) {
        lock.withLock { shouldFailWrites = value }
    }

    func blockNextWrite(thenFail: Bool) {
        lock.withLock { blockedWriteShouldFail = thenFail }
    }

    func waitUntilWriteBlocks() -> Bool {
        blockedWriteEntered.wait(timeout: .now() + 2) == .success
    }

    func releaseBlockedWrite() {
        blockedWriteRelease.signal()
    }

    func read(service: String, account: String) throws -> Data? {
        lock.withLock { storage[key(service: service, account: account)] }
    }

    func readAll(service: String) throws -> [Data] {
        lock.withLock {
            let prefix = "\(service)|"
            return storage.compactMap { item, value in item.hasPrefix(prefix) ? value : nil }
        }
    }

    func add(_ data: Data, service: String, account: String) throws {
        try blockOrFailIfNeeded()
        try lock.withLock {
            let itemKey = key(service: service, account: account)
            guard storage[itemKey] == nil else { throw SecureItemAdapterError.duplicateItem }
            storage[itemKey] = data
            writes += 1
        }
    }

    func update(_ data: Data, service: String, account: String) throws {
        try blockOrFailIfNeeded()
        try lock.withLock {
            let itemKey = key(service: service, account: account)
            guard storage[itemKey] != nil else { throw SecureItemAdapterError.itemNotFound }
            storage[itemKey] = data
            writes += 1
        }
    }

    func delete(service: String, account: String) throws {
        lock.withLock { storage[key(service: service, account: account)] = nil }
    }

    private func blockOrFailIfNeeded() throws {
        let blockedFailure = lock.withLock {
            let outcome = blockedWriteShouldFail
            blockedWriteShouldFail = nil
            return outcome
        }
        if let blockedFailure {
            blockedWriteEntered.signal()
            blockedWriteRelease.wait()
            if blockedFailure { throw SecureItemAdapterError.unavailable(status: -1) }
        }
        let shouldFail = lock.withLock { shouldFailWrites }
        guard !shouldFail else { throw SecureItemAdapterError.unavailable(status: -1) }
    }

    private func key(service: String, account: String) -> String { "\(service)|\(account)" }
}

private struct TestTimeout: Error {}
