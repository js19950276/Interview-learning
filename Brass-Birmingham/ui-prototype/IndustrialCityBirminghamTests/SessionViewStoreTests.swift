import Foundation
import Testing
@testable import IndustrialCityBirmingham

@MainActor
struct SessionViewStoreTests {
    private let room = GameCore.RoomID(rawValue: "UI42")
    private let hostID = GameCore.PlayerID(rawValue: "host")
    private let guestID = GameCore.PlayerID(rawValue: "guest")

    @Test func localUIFixtureArgumentsSelectRailPresentationOverrideOnlyWhenRequested() {
        let defaultEnvironment = AppEnvironment(arguments: ["app", "-local-ui-fixture"])
        #expect(defaultEnvironment.mode == .localUIFixture)
        #expect(defaultEnvironment.localUIFixturePresentationEraOverride == nil)

        let railEnvironment = AppEnvironment(arguments: [
            "app", "-local-ui-fixture", "-rail-fixture"
        ])
        #expect(railEnvironment.mode == .localUIFixture)
        #expect(railEnvironment.localUIFixturePresentationEraOverride == .rail)
    }

    @Test func localUIFixturePresentationOverrideChangesPresentedEraButDefaultStaysCanal() async throws {
        let defaultStore = SessionViewStore.localUIFixture()
        await defaultStore.connect()
        try await eventually { defaultStore.snapshot?.match != nil }
        #expect(defaultStore.snapshot?.match?.era == .canal)

        let railStore = SessionViewStore.localUIFixture(presentationEraOverride: .rail)
        await railStore.connect()
        try await eventually { railStore.snapshot?.match != nil }
        #expect(railStore.snapshot?.match?.era == .rail)
    }

    @Test func recipientProjectionNeverExposesOpponentHand() async throws {
        let pair = try await startedPair()

        try await eventually { pair.guestStore.snapshot != nil }
        #expect(pair.guestStore.hand == ["card-1-a", "card-1-b"])
        #expect(pair.guestStore.snapshot?.players.allSatisfy {
            $0.id == self.guestID ? $0.hand != nil : $0.hand == nil
        } == true)
    }

    @Test func passIsDisabledOutOfTurnAndDuringRecovery() async throws {
        let pair = try await startedPair()

        #expect(pair.guestStore.canSubmitPass == false)
        pair.guestStore.selectCard("card-1-a")
        #expect(pair.guestStore.canSubmitPass == false)

        pair.guestStore.setRecoveringForTesting(true)
        #expect(pair.guestStore.syncStatus == .recovering)
        #expect(pair.guestStore.canSubmitPass == false)
    }

    @Test func acceptedEventClearsDraftOnlyAfterSnapshotAdvances() async throws {
        let pair = try await startedPair()
        pair.hostStore.selectCard("card-0-a")
        let originalVersion = pair.hostStore.version

        let submission = Task { await pair.hostStore.submitPass() }
        #expect(pair.hostStore.selectedCardID == "card-0-a")
        await submission.value

        try await eventually { pair.hostStore.version.rawValue > originalVersion.rawValue }
        #expect(pair.hostStore.selectedCardID == nil)
        #expect(pair.hostStore.hand.contains("card-0-a") == false)
    }

    @Test func rejectionKeepsDraftAndShowsDirectMessage() async throws {
        let pair = try await startedPair()
        pair.guestStore.selectCard("card-1-a")
        await pair.guestStore.submitPassForTestingIgnoringTurn()

        try await eventually { pair.guestStore.errorMessage != nil }
        #expect(pair.guestStore.selectedCardID == "card-1-a")
        #expect(pair.guestStore.errorMessage == "当前不是你的行动回合。")
    }

    @Test func verifiedFriendsJourneyCoversLobbyHostOnlyStartOutOfTurnRejectionAndHostLoss() async throws {
        let catalog = try GameCore.GameDataLoader.loadBundledFixtureCatalog()
        let hub = LoopbackTransportHub()
        let host = verifiedCoordinator(
            id: hostID, token: "v2-host", transport: hub.makeTransport(peerID: hostID), catalog: catalog
        )
        let guest = verifiedCoordinator(
            id: guestID, token: "v2-guest", transport: hub.makeTransport(peerID: guestID), catalog: catalog
        )
        let hostStore = SessionViewStore(coordinator: host, role: .host)
        let guestStore = SessionViewStore(coordinator: guest, role: .guest)
        await hostStore.connect(); await guestStore.connect()
        await hostStore.setReady(true); await guestStore.setReady(true)
        try await eventually { hostStore.readyPlayerIDs.count == 2 && guestStore.readyPlayerIDs.count == 2 }
        #expect(hostStore.canStart)
        #expect(!guestStore.canStart)

        await guestStore.startGame()
        #expect(guestStore.snapshot == nil)
        #expect(guestStore.errorMessage != nil)
        await hostStore.startGame()
        try await eventually { hostStore.snapshot != nil && guestStore.snapshot != nil }

        let inactive = hostStore.snapshot?.activePlayerID == hostID ? guestStore : hostStore
        let inactiveID = inactive.localPlayerID
        let inactiveCard = try #require(inactive.snapshot?.players.first(where: { $0.id == inactiveID })?.hand?.first)
        inactive.selectCard(inactiveCard)
        #expect(!inactive.canInteract)
        await inactive.submitPassForTestingIgnoringTurn()
        try await eventually { inactive.errorMessage == "当前不是你的行动回合。" }
        #expect(inactive.selectedCardID == inactiveCard)

        await host.disconnect()
        try await eventually { guestStore.syncStatus == .recovering }
        #expect(!guestStore.canInteract)
        #expect(!guestStore.isHost)
    }

    @Test func verifiedGuestSubmissionIsDisabledWhileTransportSendIsInFlight() async throws {
        let catalog = try GameCore.GameDataLoader.loadBundledFixtureCatalog()
        var seed: UInt64 = 0
        while true {
            var setup = GameCore.SetupRules(seed: seed)
            if try setup.makeGame(catalog: catalog, playerIDs: [hostID, guestID]).state.activePlayerID == guestID { break }
            seed += 1
        }
        let hub = LoopbackTransportHub()
        let gate = StoreSendGate()
        let host = verifiedCoordinator(
            id: hostID, token: "gate-host", transport: hub.makeTransport(peerID: hostID), catalog: catalog,
            setupSeed: seed
        )
        let guest = verifiedCoordinator(
            id: guestID, token: "gate-guest",
            transport: StoreBlockingTransport(base: hub.makeTransport(peerID: guestID), gate: gate), catalog: catalog
        )
        let hostStore = SessionViewStore(coordinator: host, role: .host)
        let guestStore = SessionViewStore(coordinator: guest, role: .guest)
        await hostStore.connect(); await guestStore.connect()
        await hostStore.setReady(true); await guestStore.setReady(true)
        try await eventually { hostStore.readyPlayerIDs.count == 2 }
        await hostStore.startGame()
        try await eventually { guestStore.snapshot?.activePlayerID == guestID }
        let card = try #require(guestStore.hand.first)
        guestStore.selectCard(card)
        await gate.block()
        let submission = Task { await guestStore.submitPass() }
        try await eventually { !guestStore.canInteract }
        #expect(!guestStore.canSubmitPass)
        await gate.release()
        await submission.value
        try await eventually { guestStore.version == .init(rawValue: 1) }
    }

    @Test func lobbyAuthorizationReflectsCoordinatorRoleAndReadyState() async throws {
        let hub = LoopbackTransportHub()
        let host = coordinator(id: "host", token: "t-host", transport: hub.makeTransport(peerID: hostID))
        let guest = coordinator(id: "guest", token: "t-guest", transport: hub.makeTransport(peerID: guestID))
        let hostStore = SessionViewStore(coordinator: host, role: .host)
        let guestStore = SessionViewStore(coordinator: guest, role: .guest)

        await hostStore.connect()
        await guestStore.connect()
        try await eventually { hostStore.players.count == 2 }
        try await eventually { guestStore.players == [guestID, hostID] || guestStore.players == [hostID, guestID] }
        #expect(hostStore.canStart == false)
        #expect(guestStore.canStart == false)

        await guestStore.setReady(true)
        #expect(guestStore.isReady == false)
        try await eventually { guestStore.isReady }
        await hostStore.setReady(true)
        try await eventually { hostStore.readyPlayerIDs.count == 2 }
        try await eventually { guestStore.readyPlayerIDs.count == 2 }
        #expect(hostStore.canStart)
        #expect(guestStore.canStart == false)
    }

    @Test func hostStartButtonRejectsReadyGuestThatDisconnectedBeforeStart() async throws {
        let catalog = try GameCore.GameDataLoader.loadBundledFixtureCatalog()
        let hub = LoopbackTransportHub()
        let host = verifiedCoordinator(
            id: hostID, token: "v2-host", transport: hub.makeTransport(peerID: hostID), catalog: catalog
        )
        let guest = verifiedCoordinator(
            id: guestID, token: "v2-guest", transport: hub.makeTransport(peerID: guestID), catalog: catalog
        )
        let hostStore = SessionViewStore(coordinator: host, role: .host)
        let guestStore = SessionViewStore(coordinator: guest, role: .guest)
        await hostStore.connect()
        await guestStore.connect()
        await hostStore.setReady(true)
        await guestStore.setReady(true)
        try await eventually { hostStore.readyPlayerIDs.count == 2 }

        await guest.disconnect()
        try await eventually {
            hostStore.readyPlayerIDs.count == 2
                && hostStore.connectedPlayerIDs == [self.hostID]
        }

        #expect(hostStore.canStart == false)
        await hostStore.startGame()
        #expect(hostStore.snapshot == nil)
        #expect(hostStore.errorMessage == "仍有玩家未准备。")
    }

    @Test func allGuestsReceiveAuthoritativeRosterAndReadyUpdates() async throws {
        let hub = LoopbackTransportHub()
        let host = coordinator(id: "host", token: "t-host", transport: hub.makeTransport(peerID: hostID))
        let guest = coordinator(id: "guest", token: "t-guest", transport: hub.makeTransport(peerID: guestID))
        let thirdID = GameCore.PlayerID(rawValue: "third")
        let third = coordinator(id: "third", token: "t-third", transport: hub.makeTransport(peerID: thirdID))
        let guestStore = SessionViewStore(coordinator: guest, role: .guest)
        let thirdStore = SessionViewStore(coordinator: third, role: .guest, playerID: thirdID)
        let hostStore = SessionViewStore(coordinator: host, role: .host)
        await hostStore.connect(); await guestStore.connect(); await thirdStore.connect()
        await hostStore.setReady(true); await guestStore.setReady(true); await thirdStore.setReady(true)

        try await eventually {
            Set(guestStore.players) == [self.hostID, self.guestID, thirdID]
                && Set(thirdStore.players) == [self.hostID, self.guestID, thirdID]
                && Set(guestStore.readyPlayerIDs) == [self.hostID, self.guestID, thirdID]
                && Set(thirdStore.readyPlayerIDs) == [self.hostID, self.guestID, thirdID]
        }
    }

    @Test func disconnectFinishesCoordinatorStateSubscription() async throws {
        let hub = LoopbackTransportHub()
        let host = coordinator(id: "host", token: "t-host", transport: hub.makeTransport(peerID: hostID))
        let store = SessionViewStore(coordinator: host, role: .host)
        await store.connect()
        try await eventuallyAsync { await host.stateSubscriberCount == 1 }

        await store.disconnect()
        await store.disconnect()
        try await eventuallyAsync { await host.stateSubscriberCount == 0 }
        #expect(await host.isProcessing == false)
    }

    @Test func storeReturnsToSynchronizedAfterSuccessfulRecovery() async throws {
        let hub = LoopbackTransportHub()
        let control = StoreSendFailureControl()
        let host = coordinator(id: "host", token: "t-host",
                               transport: StoreSelectiveFailingTransport(base: hub.makeTransport(peerID: hostID), control: control))
        let guest = coordinator(id: "guest", token: "t-guest", transport: hub.makeTransport(peerID: guestID))
        let store = SessionViewStore(coordinator: host, role: .host)
        await store.connect(); try await guest.joinRoom()
        await store.setReady(true); try await guest.setReady(true)
        try await eventually { store.readyPlayerIDs.count == 2 }
        await store.startGame(); try await eventually { store.snapshot != nil }
        await control.failSends(to: guestID)
        store.selectCard("card-0-a"); await store.submitPass()
        try await eventually { store.syncStatus == .recovering }

        await control.restoreSends(to: guestID); await guest.disconnect()
        let reconnected = coordinator(id: "guest", token: "t-guest", transport: hub.makeTransport(peerID: guestID))
        try await reconnected.joinRoom()
        try await eventually { store.syncStatus == .synchronized }
        #expect(store.snapshot?.activePlayerID == guestID)
    }

    @Test func inactiveGuestDisconnectDoesNotBlockTheOnlineActiveHost() async throws {
        let hub = LoopbackTransportHub()
        let inactiveID = GameCore.PlayerID(rawValue: "z-inactive")
        let host = coordinator(
            id: hostID.rawValue, token: "t-host",
            transport: hub.makeTransport(peerID: hostID)
        )
        let nextGuest = coordinator(
            id: guestID.rawValue, token: "t-guest",
            transport: hub.makeTransport(peerID: guestID)
        )
        let inactiveGuest = coordinator(
            id: inactiveID.rawValue, token: "t-inactive",
            transport: hub.makeTransport(peerID: inactiveID)
        )
        let store = SessionViewStore(coordinator: host, role: .host)

        await store.connect()
        try await nextGuest.joinRoom()
        try await inactiveGuest.joinRoom()
        await store.setReady(true)
        try await nextGuest.setReady(true)
        try await inactiveGuest.setReady(true)
        try await eventually { store.readyPlayerIDs.count == 3 }
        await store.startGame()
        try await eventually { store.snapshot?.activePlayerID == hostID }

        await inactiveGuest.disconnect()
        try await eventuallyAsync { await host.peersNeedingRecovery == [inactiveID] }
        try await eventually { store.syncStatus == .synchronized }

        let card = try #require(store.hand.first)
        store.selectCard(card)
        #expect(store.canSubmitPass)
    }

    @Test func successfulLobbyRebroadcastClearsRecovery() async throws {
        let hub = LoopbackTransportHub(); let control = StoreSendFailureControl()
        let host = coordinator(id: "host", token: "t-host",
            transport: StoreSelectiveFailingTransport(base: hub.makeTransport(peerID: hostID), control: control))
        let guest = coordinator(id: "guest", token: "t-guest", transport: hub.makeTransport(peerID: guestID))
        let store = SessionViewStore(coordinator: host, role: .host)
        await store.connect(); try await guest.joinRoom(); try await eventually { store.players.count == 2 }
        await control.failSends(to: guestID); await store.setReady(true)
        try await eventually { store.syncStatus == .recovering }
        await control.restoreSends(to: guestID); await store.setReady(false)
        try await eventually { store.syncStatus == .synchronized }
        #expect(await host.peersNeedingRecovery.isEmpty)
        #expect(await host.lastDeliveryError == nil)
    }

    private func startedPair() async throws -> (hostStore: SessionViewStore, guestStore: SessionViewStore) {
        let hub = LoopbackTransportHub()
        let host = coordinator(id: "host", token: "t-host", transport: hub.makeTransport(peerID: hostID))
        let guest = coordinator(id: "guest", token: "t-guest", transport: hub.makeTransport(peerID: guestID))
        let hostStore = SessionViewStore(coordinator: host, role: .host)
        let guestStore = SessionViewStore(coordinator: guest, role: .guest)
        await hostStore.connect()
        await guestStore.connect()
        try await eventually { hostStore.players.count == 2 }
        await hostStore.setReady(true)
        await guestStore.setReady(true)
        try await eventually { hostStore.readyPlayerIDs.count == 2 }
        await hostStore.startGame()
        try await eventually { hostStore.snapshot != nil && guestStore.snapshot != nil }
        return (hostStore, guestStore)
    }

    private func coordinator(id: String, token: String, transport: some Transport) -> SessionCoordinator {
        SessionCoordinator(configuration: .init(
            protocolVersion: 1,
            rulesetVersion: "rules-v1",
            roomID: room,
            playerID: .init(rawValue: id),
            reconnectToken: .init(rawValue: token),
            hostPlayerID: hostID
        ), transport: transport, rulesMode: .fixtureOnlyLegacy)
    }

    private func verifiedCoordinator(
        id: GameCore.PlayerID,
        token: String,
        transport: some Transport,
        catalog: GameCore.VerifiedGameDataCatalog,
        setupSeed: UInt64 = 1
    ) -> SessionCoordinator {
        SessionCoordinator(configuration: .init(
            protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion,
            roomID: room, playerID: id, reconnectToken: .init(rawValue: token),
            hostPlayerID: hostID, setupSeed: setupSeed
        ), transport: transport, rulesMode: .verified(catalog))
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SessionViewStoreTimeout()
    }

    private func eventuallyAsync(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SessionViewStoreTimeout()
    }
}

private struct SessionViewStoreTimeout: Error {}

private actor StoreSendGate {
    private var blocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func block() { blocked = true }
    func waitIfBlocked() async {
        guard blocked else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        blocked = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor StoreBlockingTransport: Transport {
    nonisolated let events: AsyncStream<TransportEvent>
    private let base: LoopbackTransport
    private let gate: StoreSendGate
    init(base: LoopbackTransport, gate: StoreSendGate) {
        self.base = base; self.gate = gate; events = base.events
    }
    func startHosting(roomID: GameCore.RoomID, port: UInt16?) async throws {
        try await base.startHosting(roomID: roomID, port: port)
    }
    func browse() async throws { try await base.browse() }
    func connect(to peer: GameCore.PlayerID) async throws { try await base.connect(to: peer) }
    func send(_ data: Data, to peer: GameCore.PlayerID) async throws {
        await gate.waitIfBlocked()
        try await base.send(data, to: peer)
    }
    func disconnect() async { await base.disconnect() }
}

private actor StoreSendFailureControl {
    private var failedPeers: Set<GameCore.PlayerID> = []
    func failSends(to peer: GameCore.PlayerID) { failedPeers.insert(peer) }
    func restoreSends(to peer: GameCore.PlayerID) { failedPeers.remove(peer) }
    func shouldFail(_ peer: GameCore.PlayerID) -> Bool { failedPeers.contains(peer) }
}

private actor StoreSelectiveFailingTransport: Transport {
    nonisolated let events: AsyncStream<TransportEvent>
    private let base: LoopbackTransport
    private let control: StoreSendFailureControl

    init(base: LoopbackTransport, control: StoreSendFailureControl) {
        self.base = base; self.control = control; self.events = base.events
    }

    func startHosting(roomID: GameCore.RoomID, port: UInt16?) async throws { try await base.startHosting(roomID: roomID, port: port) }
    func browse() async throws { try await base.browse() }
    func connect(to peer: GameCore.PlayerID) async throws { try await base.connect(to: peer) }
    func send(_ data: Data, to peer: GameCore.PlayerID) async throws {
        if await control.shouldFail(peer) { throw TransportError.connectionFailed }
        try await base.send(data, to: peer)
    }
    func disconnect() async { await base.disconnect() }
}
