import Foundation
import Network
import Testing
@testable import IndustrialCityBirmingham

@Suite("Nearby peer-to-peer transport")
struct NearbyTransportTests {
    @MainActor
    @Test func debugSimulatorNearbyHostCreatesWithoutLaunchSwitches() async throws {
        let store = try await SessionViewStore.nearbyHost(
            roomID: .init(rawValue: "BRASS-UNIT-\(UUID().uuidString.prefix(6))"),
            identity: NearbySessionIdentity(deviceID: UUID()),
            catalog: GameCore.GameDataLoader.loadBundledFixtureCatalog()
        )

        let issue = await store.connect()
        #expect(issue == nil)
        await store.disconnect()
    }

    @Test func debugSimulatorNearbyBrowserUsesLocalServiceWithoutLaunchSwitches() {
        #expect(NetworkBonjourBrowserDriver.runtimeServiceType == LocalNetworkTransport.serviceType)
    }

    @MainActor
    @Test func fatalCatalogLoadFailureLatchesAcrossSearchingAndFoundBrowserUpdates() async {
        var state = NearbyProductionState()
        state = await state.loadingRecoveryPrerequisites(
            catalogLoader: { throw GameCore.GameDataLoadError.bundledResourceMissing("manifest.json") },
            roomsLoader: { _ in
                Issue.record("Room loading must not run without a verified catalog")
                return []
            }
        )

        #expect(state.browseState == .failed(.gameDataUnavailable))
        state.receiveBrowserState(.searching)
        state.receiveBrowserState(.found([NearbyRoom(serviceName: "BRASS-FOUND")!]))

        #expect(state.browseState == .failed(.gameDataUnavailable))
        #expect(state.fatalIssue == .gameDataUnavailable)
        #expect(state.canStartBrowsing == false)
        #expect(state.canRetryBrowsing == false)
        #expect(state.interactionsDisabled)
        #expect(state.catalog == nil)
    }

    @MainActor
    @Test func operationalFailureLatchesAcrossBrowserUpdatesUntilExplicitRetry() async throws {
        var state = NearbyProductionState()
        state = await state.loadingRecoveryPrerequisites(
            catalogLoader: { try nearbyVerifiedCatalog() },
            roomsLoader: { _ in [] }
        )

        state.receiveOperationalFailure(.connectionFailed)
        state.receiveBrowserState(.searching)
        state.receiveBrowserState(.found([try #require(NearbyRoom(serviceName: "BRASS-FOUND"))]))

        #expect(state.browseState == .failed(.connectionFailed))
        #expect(!state.interactionsDisabled)
        #expect(state.canRetryBrowsing)

        state.restartSearching()
        #expect(state.browseState == .searching)
        #expect(!state.interactionsDisabled)

        let room = try #require(NearbyRoom(serviceName: "BRASS-RETRIED"))
        state.receiveBrowserState(.found([room]))
        #expect(state.browseState == .found([room]))
    }

    @Test func ordinaryDebugLaunchUsesProductionNearbyWithFixtureRulesAndNoSwitch() {
        let environment = AppEnvironment(arguments: ["IndustrialCityBirmingham"])
        #expect(environment.usesFixtureSession == false)
        #expect(NearbyRoomPresentationMode.resolve(fixtureSessionAvailable: false) == .production)
        #expect(environment.nearbyCatalogSource == .debugFixture)
    }

    @Test(arguments: [
        ["IndustrialCityBirmingham", "-ui-testing"],
        ["IndustrialCityBirmingham", "-snapshot-testing"],
        ["IndustrialCityBirmingham", "-fixture", "players4"],
        ["IndustrialCityBirmingham", "-demo-ui"],
    ])
    func explicitDemoArgumentsRetainDeterministicFixtureSession(arguments: [String]) {
        let environment = AppEnvironment(arguments: arguments)
        #expect(environment.usesFixtureSession)
        #expect(NearbyRoomPresentationMode.resolve(fixtureSessionAvailable: true) == .fixture)
    }

    @Test func deviceIdentityProducesAStableSeatButRoomScopedOpaqueReconnectTokens() {
        let deviceID = UUID(uuidString: "B305FCF8-F7CA-427E-8D47-83263A3D23F7")!
        let first = NearbySessionIdentity(deviceID: deviceID)
        let second = NearbySessionIdentity(deviceID: deviceID)
        let cabin = GameCore.RoomID(rawValue: "BRASS-CABIN")
        let foundry = GameCore.RoomID(rawValue: "BRASS-FOUNDRY")

        #expect(first == second)
        #expect(first.playerID.rawValue == "guest-b305fcf8")
        #expect(first.reconnectToken(for: cabin) == second.reconnectToken(for: cabin))
        #expect(first.reconnectToken(for: cabin) != first.reconnectToken(for: foundry))
        #expect(!first.reconnectToken(for: cabin).rawValue.contains(deviceID.uuidString.lowercased()))
    }

    @Test func missingVendorIdentifierReusesTheSameIdentityWithinTheProcess() {
        let first = NearbySessionIdentity.make(deviceID: nil)
        let second = NearbySessionIdentity.make(deviceID: nil)

        #expect(first == second)
        #expect(first.playerID == second.playerID)
        #expect(first.reconnectToken(for: .init(rawValue: "CABIN"))
            == second.reconnectToken(for: .init(rawValue: "CABIN")))
    }

    @Test func nearbyUsesProductionBonjourServiceAndPeerToPeerTCPParameters() {
        #expect(NearbyTransport.serviceType == "_industrialcity._tcp")
        #expect(LocalNetworkTransport.serviceType == "_industrialcity-dev._tcp")

        let parameters = NearbyTransport.makeParameters()
        #expect(parameters.includePeerToPeer)
        #expect(parameters.preferNoProxies)
    }

    @Test func advertisedServiceKeepsSanitizedRoomNameStableInsteadOfAutoRenaming() {
        let service = NearbyTransport.makeService(roomID: .init(rawValue: " Bräss / Cabin "))
        #expect(service.name == "BRASS-CABIN")
        #expect(service.type == "_industrialcity._tcp")
        #expect(service.noAutoRename)
    }

    @Test func transportShutdownGateAllowsResourceReleaseExactlyOnce() {
        var gate = TransportShutdownGate()
        let first = gate.begin()
        let second = gate.begin()
        let third = gate.begin()
        #expect(first)
        #expect(!second)
        #expect(!third)
    }

    @Test func unauthenticatedPeerGateEnforcesCapacityAndReleasesAuthenticatedOrClosedPeers() {
        var gate = NearbyUnauthenticatedPeerGate(capacity: 2)
        let first = GameCore.PlayerID(rawValue: "first")
        let second = GameCore.PlayerID(rawValue: "second")
        let third = GameCore.PlayerID(rawValue: "third")

        let admittedFirst = gate.admit(first)
        let admittedSecond = gate.admit(second)
        let rejectedAtCapacity = gate.admit(third)
        let authenticatedFirst = gate.authenticate(first)
        let admittedAfterAuthentication = gate.admit(third)

        #expect(admittedFirst)
        #expect(admittedSecond)
        #expect(!rejectedAtCapacity)
        #expect(authenticatedFirst)
        #expect(admittedAfterAuthentication)
        gate.terminate(second)
        #expect(gate.pending == [third])
    }

    @Test func admittedPeerDoesNotEnterTheAuthenticationWindowUntilItsConnectionIsReady() {
        var gate = NearbyUnauthenticatedPeerGate(capacity: 1)
        let peer = GameCore.PlayerID(rawValue: "slow-ready-peer")

        let admitted = gate.admit(peer)
        let beforeReady = gate.readyForAuthentication
        let enteredAuthenticationWindow = gate.markReady(peer)
        let duplicateReady = gate.markReady(peer)

        #expect(admitted)
        #expect(beforeReady.isEmpty)
        #expect(enteredAuthenticationWindow)
        #expect(!duplicateReady)
        #expect(gate.pending == [peer])
        #expect(gate.readyForAuthentication == [peer])
    }

    @Test func lifecycleGateReturnsOnlyAfterTheNetworkResourceIsReady() async throws {
        let driver = TestNearbyLifecycleDriver()
        let gate = NearbyLifecycleGate()
        let task = Task {
            try await gate.waitUntilReady(start: driver.start, cancel: driver.cancel)
        }

        try await eventually { driver.startCount == 1 }
        #expect(task.isCancelled == false)
        driver.emit(.ready)
        try await task.value

        #expect(gate.completionCount == 1)
        #expect(driver.cancelCount == 0)
    }

    @Test(arguments: [
        NearbyPreflightIssue.permissionDenied,
        NearbyPreflightIssue.wirelessOff,
        NearbyPreflightIssue.connectionFailed,
    ])
    func lifecycleGateMapsWaitingAndFailedStatesToActionableIssues(issue: NearbyPreflightIssue) async throws {
        for update in [NearbyLifecycleUpdate.waiting(issue), .failed(issue)] {
            let driver = TestNearbyLifecycleDriver()
            let gate = NearbyLifecycleGate()
            let task = Task {
                try await gate.waitUntilReady(start: driver.start, cancel: driver.cancel)
            }
            try await eventually { driver.startCount == 1 }
            driver.emit(update)
            await #expect(throws: issue) { try await task.value }
            #expect(driver.cancelCount == 1)
            #expect(gate.completionCount == 1)
        }
    }

    @Test func lifecycleGateCompletesAndCancelsExactlyOnceDuringACancelFailureRace() async throws {
        let driver = TestNearbyLifecycleDriver()
        let gate = NearbyLifecycleGate()
        let task = Task {
            try await gate.waitUntilReady(start: driver.start, cancel: driver.cancel)
        }
        try await eventually { driver.startCount == 1 }

        task.cancel()
        driver.emit(.failed(.connectionFailed))
        await #expect(throws: NearbyPreflightIssue.connectionFailed) { try await task.value }
        #expect(driver.cancelCount == 1)
        #expect(gate.completionCount == 1)
    }

    @Test func lifecycleGateCancelsAConnectionThatNeverBecomesReady() async {
        let driver = TestNearbyLifecycleDriver()
        let gate = NearbyLifecycleGate()

        await #expect(throws: NearbyPreflightIssue.connectionFailed) {
            try await gate.waitUntilReady(
                timeout: .milliseconds(25),
                start: driver.start,
                cancel: driver.cancel
            )
        }
        #expect(driver.startCount == 1)
        #expect(driver.cancelCount == 1)
        #expect(gate.completionCount == 1)
    }

    @Test(arguments: [
        ("  Bräss / Flight # 42  ", "BRASS-FLIGHT-42"),
        ("---BRASS---CABIN---", "BRASS-CABIN"),
        ("伯明翰", "ROOM"),
        (String(repeating: "A", count: 80), String(repeating: "A", count: 40)),
    ])
    func roomNamesAreSanitizedDeterministically(input: String, expected: String) {
        #expect(NearbyServiceName.sanitize(input) == expected)
        #expect(NearbyServiceName.sanitize(input) == NearbyServiceName.sanitize(input))
    }

    @Test func browserAddsRemovesAndSuppressesDuplicateRooms() async throws {
        let driver = TestBonjourBrowserDriver()
        let browser = BonjourPeerBrowser(driver: driver)
        let recorder = StateRecorder<NearbyBrowseState>()
        let collection = Task {
            for await state in browser.states { await recorder.append(state) }
        }

        await browser.start()
        let room = try #require(NearbyRoom(serviceName: "BRASS-CABIN"))
        let instance = try #require(BonjourServiceInstance(endpointID: "cabin.local|en0", serviceName: room.serviceName))
        driver.emit(.added(instance))
        try await eventually { await browser.rooms == [room] }
        driver.emit(.added(instance))
        try await Task.sleep(for: .milliseconds(30))
        driver.emit(.removed(instance.id))
        try await eventually { await browser.rooms.isEmpty }

        let states = await recorder.values
        #expect(states.filter { $0 == .found([room]) }.count == 1)
        #expect(states.contains(.empty))
        await browser.cancel()
        collection.cancel()
    }

    @Test func browserKeepsARoomUntilItsLastBonjourEndpointInstanceDisappears() async throws {
        let driver = TestBonjourBrowserDriver()
        let browser = BonjourPeerBrowser(driver: driver)
        let first = try #require(BonjourServiceInstance(
            endpointID: "Bräss|_industrialcity._tcp|local.|en0",
            serviceName: "Bräss"
        ))
        let second = try #require(BonjourServiceInstance(
            endpointID: "BRASS|_industrialcity._tcp|cabin.local.|awdl0",
            serviceName: "BRASS"
        ))

        await browser.start()
        driver.emit(.added(first))
        driver.emit(.added(second))
        try await eventually { await browser.rooms == [first.room] }

        driver.emit(.removed(first.id))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await browser.rooms == [first.room])

        driver.emit(.removed(second.id))
        try await eventually { await browser.rooms.isEmpty }
        await browser.cancel()
    }

    @Test func changingOnlyTheBrowseResultInterfaceSetDoesNotRemoveOrReaddTheRoom() throws {
        var tracker = BonjourResultTracker()
        let first = BonjourResultSnapshot(
            name: "BRASS-CABIN", type: "_industrialcity._tcp", domain: "local.",
            endpointInterface: "en0", resultInterfaces: ["en0"]
        )
        let expanded = BonjourResultSnapshot(
            name: "BRASS-CABIN", type: "_industrialcity._tcp", domain: "local.",
            endpointInterface: "en0", resultInterfaces: ["awdl0", "en0"]
        )

        let initial = tracker.updates(for: [first])
        let interfaceOnlyChange = tracker.updates(for: [expanded])

        #expect(initial.count == 1)
        #expect(interfaceOnlyChange.isEmpty)
        #expect(!interfaceOnlyChange.contains { if case .removed = $0 { true } else { false } })
    }

    @Test func cancellingBrowserTwiceCancelsDriverAndFinishesStateStreamOnce() async throws {
        let driver = TestBonjourBrowserDriver()
        let browser = BonjourPeerBrowser(driver: driver)
        let completion = StreamCompletionCounter()
        let collection = Task {
            for await _ in browser.states {}
            await completion.record()
        }

        await browser.start()
        await browser.cancel()
        await browser.cancel()
        try await eventually { await completion.count == 1 }

        #expect(driver.startCount == 1)
        #expect(driver.cancelCount == 1)
        _ = await collection.result
    }

    @Test(arguments: [
        (NWError.posix(.EPERM), NearbyPreflightIssue.permissionDenied),
        (NWError.dns(-65570), NearbyPreflightIssue.permissionDenied),
        (NWError.posix(.ENETDOWN), NearbyPreflightIssue.wirelessOff),
        (NWError.posix(.ENETUNREACH), NearbyPreflightIssue.wirelessOff),
        (NWError.posix(.ECONNREFUSED), NearbyPreflightIssue.connectionFailed),
    ])
    func networkErrorsProduceActionablePreflightIssues(error: NWError, expected: NearbyPreflightIssue) {
        #expect(NearbyPreflight.issue(for: error) == expected)
        #expect(!expected.recoveryMessage.isEmpty)
    }

    @Test(arguments: [
        (TransportError.notConnected as any Error, NearbyPreflightIssue.noRooms),
        (TransportError.connectionFailed as any Error, NearbyPreflightIssue.connectionFailed),
        (SessionCoordinator.Error.joinTimedOut as any Error, NearbyPreflightIssue.connectionFailed),
        (NearbyPreflightIssue.permissionDenied as any Error, NearbyPreflightIssue.permissionDenied),
        (NearbyPreflightIssue.wirelessOff as any Error, NearbyPreflightIssue.wirelessOff),
    ])
    func connectionErrorsPreserveActionableNearbyClassification(error: any Error, expected: NearbyPreflightIssue) {
        #expect(NearbyPreflight.issue(for: error) == expected)
    }

    @Test func seatPersistenceFailureHasDistinctSaveAndRetryGuidance() {
        let issue = NearbyPreflight.issue(for: SessionCoordinator.Error.persistenceUnavailable)

        #expect(issue.rawValue == "persistenceUnavailable")
        #expect(issue.title == "无法安全保存座位")
        #expect(issue.recoveryMessage.contains("房主"))
        #expect(issue.recoveryMessage.contains("保存"))
        #expect(issue.recoveryMessage.contains("重试"))
        #expect(!issue.recoveryMessage.contains("靠近"))
    }

    @MainActor
    @Test func guestStoreShowsSeatPersistenceRecoveryInsteadOfNetworkProximityAdvice() async {
        let roomID = GameCore.RoomID(rawValue: "PERSIST-SEAT")
        let hostID = GameCore.PlayerID(rawValue: "host")
        let guestID = GameCore.PlayerID(rawValue: "guest")
        let hub = LoopbackTransportHub()
        let adapter = FailingSeatPersistenceSecureItemAdapter()
        let host = makeCoordinator(
            id: hostID, token: "host-token", hostID: hostID,
            transport: hub.makeTransport(peerID: hostID),
            tokenStore: RoomTokenStore(adapter: adapter), roomID: roomID
        )
        let guest = makeCoordinator(
            id: guestID, token: "guest-token", hostID: hostID,
            transport: hub.makeTransport(peerID: guestID), roomID: roomID
        )
        let hostStore = SessionViewStore(coordinator: host, role: .host)
        let guestStore = SessionViewStore(coordinator: guest, role: .guest)

        #expect(await hostStore.connect() == nil)
        adapter.setFailWrites(true)
        let issue = await guestStore.connect()

        #expect(issue?.rawValue == "persistenceUnavailable")
        #expect(guestStore.syncStatus == .failed)
        #expect(guestStore.errorMessage?.contains("保存") == true)
        #expect(guestStore.errorMessage?.contains("重试") == true)
        #expect(guestStore.errorMessage?.contains("靠近") == false)
        await guestStore.disconnect()
        await hostStore.disconnect()
    }

    @MainActor
    @Test(arguments: [
        NearbyPreflightIssue.permissionDenied,
        NearbyPreflightIssue.wirelessOff,
        NearbyPreflightIssue.connectionFailed,
        NearbyPreflightIssue.noRooms,
    ])
    func nearbyStoreReturnsPreflightFailureBeforePresentingTheLobby(issue: NearbyPreflightIssue) async {
        let hostID = GameCore.PlayerID(rawValue: "host")
        let coordinator = SessionCoordinator(configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: .init(rawValue: "CABIN"),
            playerID: hostID, reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
        ), transport: FailingNearbyTransport(issue: issue), rulesMode: .fixtureOnlyLegacy)
        let store = SessionViewStore(coordinator: coordinator, role: .host)

        let result = await store.connect()

        #expect(result == issue)
        #expect(store.syncStatus == .failed)
        #expect(store.errorMessage == issue.recoveryMessage)
        await store.disconnect()
    }

    @MainActor
    @Test func disconnectedSessionStoreRejectsReconnectAsATerminalOneShotSession() async {
        let hostID = GameCore.PlayerID(rawValue: "host")
        let transport = CountingTransport()
        let coordinator = SessionCoordinator(configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: .init(rawValue: "CABIN"),
            playerID: hostID, reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
        ), transport: transport, rulesMode: .fixtureOnlyLegacy)
        let store = SessionViewStore(coordinator: coordinator, role: .host)

        #expect(await store.connect() == nil)
        await store.disconnect()
        #expect(await store.connect() == .sessionEnded)
        #expect(await transport.hostStartCount == 1)
    }

    @Test func noRoomStateHasExplicitRetryGuidanceWithoutBluetoothPermissionClaim() {
        let issue = NearbyPreflightIssue.noRooms
        #expect(issue.recoveryMessage.contains("重试"))
        #expect(issue.recoveryMessage.contains("Wi-Fi"))
        #expect(!issue.recoveryMessage.contains("蓝牙权限"))
    }

    @Test func sessionBoundaryRequiresAtLeastTwoSeatsAndRejectsAFifthSeat() async throws {
        let hub = LoopbackTransportHub()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let host = makeCoordinator(id: hostID, token: "host-token", hostID: hostID,
                                   transport: hub.makeTransport(peerID: hostID))
        try await host.createRoom()
        try await host.setReady(true)
        await #expect(throws: SessionCoordinator.Error.notAllPlayersReady) {
            try await host.startGame()
        }

        for index in 1...3 {
            let id = GameCore.PlayerID(rawValue: "guest-\(index)")
            let guest = makeCoordinator(id: id, token: "token-\(index)", hostID: hostID,
                                        transport: hub.makeTransport(peerID: id))
            try await guest.joinRoom()
        }
        let fifthID = GameCore.PlayerID(rawValue: "guest-4")
        let fifth = makeCoordinator(id: fifthID, token: "token-4", hostID: hostID,
                                    transport: hub.makeTransport(peerID: fifthID))
        await #expect(throws: SessionCoordinator.Error.roomFull) { try await fifth.joinRoom() }
        #expect(await host.playerIDs.count == 4)
    }

    @Test func reconnectWithTheSameSeatTokenReusesTheAssignedSeat() async throws {
        let hub = LoopbackTransportHub()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let guestID = GameCore.PlayerID(rawValue: "guest")
        let host = makeCoordinator(id: hostID, token: "host-token", hostID: hostID,
                                   transport: hub.makeTransport(peerID: hostID))
        let firstGuest = makeCoordinator(id: guestID, token: "stable-token", hostID: hostID,
                                         transport: hub.makeTransport(peerID: .init(rawValue: "guest-link-1")))
        try await host.createRoom()
        try await firstGuest.joinRoom()
        try await eventually { await host.playerIDs.count == 2 }
        await firstGuest.disconnect()

        let reconnectedGuest = makeCoordinator(id: guestID, token: "stable-token", hostID: hostID,
                                               transport: hub.makeTransport(peerID: .init(rawValue: "guest-link-2")))
        try await reconnectedGuest.joinRoom()
        try await eventually { await host.playerIDs.count == 2 }
        #expect(await host.playerIDs == [guestID, hostID])
    }

    @Test func hostAuthenticatesTheTransportPeerOnlyAfterAcceptingItsHello() async throws {
        let hub = LoopbackTransportHub()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let guestID = GameCore.PlayerID(rawValue: "guest")
        let guestLink = GameCore.PlayerID(rawValue: "guest-link")
        let recorder = AuthenticationRecorder()
        let hostTransport = AuthenticationRecordingTransport(
            base: hub.makeTransport(peerID: hostID), recorder: recorder
        )
        let host = makeCoordinator(
            id: hostID, token: "host-token", hostID: hostID, transport: hostTransport
        )
        let guest = makeCoordinator(
            id: guestID, token: "guest-token", hostID: hostID,
            transport: hub.makeTransport(peerID: guestLink)
        )

        try await host.createRoom()
        try await guest.joinRoom()
        try await eventually { await recorder.authenticatedPeers == [guestLink] }

        #expect(await recorder.authenticatedPeers == [guestLink])
        await guest.disconnect()
        await host.disconnect()
    }

    @Test func hostDoesNotAuthenticateATransportPeerWhoseHelloIsRejected() async throws {
        let hub = LoopbackTransportHub()
        let hostID = GameCore.PlayerID(rawValue: "host")
        let rogueID = GameCore.PlayerID(rawValue: "rogue-link")
        let recorder = AuthenticationRecorder()
        let hostTransport = AuthenticationRecordingTransport(
            base: hub.makeTransport(peerID: hostID), recorder: recorder
        )
        let host = makeCoordinator(
            id: hostID, token: "host-token", hostID: hostID, transport: hostTransport
        )
        let rogue = hub.makeTransport(peerID: rogueID)

        try await host.createRoom()
        try await rogue.connect(to: hostID)
        let rejectedHello = SessionProtocol.SessionEnvelope(
            protocolVersion: 1,
            rulesetVersion: "rules-v1",
            roomID: .init(rawValue: "OTHER-ROOM"),
            messageID: .init(rawValue: "rogue-hello"),
            senderID: .init(rawValue: "rogue-seat"),
            recipientID: hostID,
            authoritativeVersion: .init(rawValue: 0),
            payload: .hello(reconnectToken: .init(rawValue: "rogue-token"))
        )
        try await rogue.send(JSONEncoder().encode(rejectedHello), to: hostID)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await recorder.authenticatedPeers.isEmpty)
        await rogue.disconnect()
        await host.disconnect()
    }

    private func makeCoordinator(
        id: GameCore.PlayerID,
        token: String,
        hostID: GameCore.PlayerID,
        transport: some Transport,
        tokenStore: RoomTokenStore? = nil,
        roomID: GameCore.RoomID = .init(rawValue: "CABIN")
    ) -> SessionCoordinator {
        SessionCoordinator(configuration: .init(
            protocolVersion: 1,
            rulesetVersion: "rules-v1",
            roomID: roomID,
            playerID: id,
            reconnectToken: .init(rawValue: token),
            hostPlayerID: hostID
        ), transport: transport, tokenStore: tokenStore, rulesMode: .fixtureOnlyLegacy)
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
        Issue.record("Condition did not become true before timeout")
    }
}

private func nearbyVerifiedCatalog() throws -> GameCore.VerifiedGameDataCatalog {
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
            id: "nearby-tests", url: "https://example.invalid/rules",
            component: "rules", version: "2018.11", page: "all",
            transcriber: "test", transcribedOn: "2026-08-18",
            checker: "independent-test", checkedOn: "2026-08-18"
        )]
    )
    return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
        manifestData: JSONEncoder().encode(manifest), files: files
    )
}

private final class TestBonjourBrowserDriver: BonjourBrowserDriving, @unchecked Sendable {
    nonisolated let updates: AsyncStream<BonjourBrowserUpdate>
    private let continuation: AsyncStream<BonjourBrowserUpdate>.Continuation
    private let lock = NSLock()
    private var starts = 0
    private var cancellations = 0

    init() {
        (updates, continuation) = AsyncStream.makeStream(of: BonjourBrowserUpdate.self)
    }

    var startCount: Int { lock.withLock { starts } }
    var cancelCount: Int { lock.withLock { cancellations } }

    func start() { lock.withLock { starts += 1 } }
    func cancel() {
        lock.withLock { cancellations += 1 }
        continuation.finish()
    }
    func emit(_ update: BonjourBrowserUpdate) { continuation.yield(update) }
}

private final class TestNearbyLifecycleDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (NearbyLifecycleUpdate) -> Void)?
    private var starts = 0
    private var cancellations = 0

    var startCount: Int { lock.withLock { starts } }
    var cancelCount: Int { lock.withLock { cancellations } }

    func start(_ handler: @escaping @Sendable (NearbyLifecycleUpdate) -> Void) {
        lock.withLock {
            starts += 1
            self.handler = handler
        }
    }

    func cancel() { lock.withLock { cancellations += 1 } }
    func emit(_ update: NearbyLifecycleUpdate) { lock.withLock { handler }?(update) }
}

private actor StateRecorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

private actor StreamCompletionCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private final class FailingSeatPersistenceSecureItemAdapter: SecureItemAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var shouldFailWrites = false

    func setFailWrites(_ value: Bool) {
        lock.withLock { shouldFailWrites = value }
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
        try lock.withLock {
            guard !shouldFailWrites else { throw SecureItemAdapterError.unavailable(status: -1) }
            let itemKey = key(service: service, account: account)
            guard storage[itemKey] == nil else { throw SecureItemAdapterError.duplicateItem }
            storage[itemKey] = data
        }
    }

    func update(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            guard !shouldFailWrites else { throw SecureItemAdapterError.unavailable(status: -1) }
            let itemKey = key(service: service, account: account)
            guard storage[itemKey] != nil else { throw SecureItemAdapterError.itemNotFound }
            storage[itemKey] = data
        }
    }

    func delete(service: String, account: String) throws {
        lock.withLock { storage[key(service: service, account: account)] = nil }
    }

    private func key(service: String, account: String) -> String { "\(service)|\(account)" }
}

private actor FailingNearbyTransport: Transport {
    nonisolated let events: AsyncStream<TransportEvent>
    private let issue: NearbyPreflightIssue

    init(issue: NearbyPreflightIssue) {
        self.issue = issue
        (events, _) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    func startHosting(roomID: GameCore.RoomID, port: UInt16?) async throws { throw issue }
    func browse() async throws { if issue == .noRooms { throw TransportError.notConnected } }
    func connect(to peer: GameCore.PlayerID) async throws { throw issue }
    func send(_ data: Data, to peer: GameCore.PlayerID) async throws { throw issue }
    func disconnect() {}
}

private actor CountingTransport: Transport {
    nonisolated let events: AsyncStream<TransportEvent>
    private(set) var hostStartCount = 0

    init() { (events, _) = AsyncStream.makeStream(of: TransportEvent.self) }
    func startHosting(roomID: GameCore.RoomID, port: UInt16?) { hostStartCount += 1 }
    func browse() {}
    func connect(to peer: GameCore.PlayerID) {}
    func send(_ data: Data, to peer: GameCore.PlayerID) {}
    func disconnect() {}
}

private actor AuthenticationRecorder {
    private(set) var authenticatedPeers: [GameCore.PlayerID] = []
    func record(_ peer: GameCore.PlayerID) { authenticatedPeers.append(peer) }
}

private actor AuthenticationRecordingTransport: Transport {
    nonisolated let events: AsyncStream<TransportEvent>
    private let base: LoopbackTransport
    private let recorder: AuthenticationRecorder

    init(base: LoopbackTransport, recorder: AuthenticationRecorder) {
        self.base = base
        self.recorder = recorder
        events = base.events
    }

    func startHosting(roomID: GameCore.RoomID, port: UInt16?) async throws {
        try await base.startHosting(roomID: roomID, port: port)
    }

    func browse() async throws { try await base.browse() }
    func connect(to peer: GameCore.PlayerID) async throws { try await base.connect(to: peer) }
    func authenticate(_ peer: GameCore.PlayerID) async {
        await recorder.record(peer)
        await base.authenticate(peer)
    }
    func send(_ data: Data, to peer: GameCore.PlayerID) async throws {
        try await base.send(data, to: peer)
    }
    func disconnect() async { await base.disconnect() }
}
