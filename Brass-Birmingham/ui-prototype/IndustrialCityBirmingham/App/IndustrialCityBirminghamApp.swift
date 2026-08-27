import SwiftUI

@main
struct IndustrialCityBirminghamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#if DEBUG
    @State private var session: DemoSessionStore?
#endif
    @State private var preferences = MotionPreferences()
    @State private var realSession: SessionViewStore?
    @State private var nearbyPersistenceState: NearbyPersistenceState
    private let launchConfiguration: DemoLaunchConfiguration
    private let environment: AppEnvironment

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let configuration = DemoLaunchConfiguration(arguments: arguments)
        let environment = AppEnvironment(arguments: arguments)
#if DEBUG
        let usesDemoFixture = environment.localHarness == nil && environment.usesFixtureSession
        let session: DemoSessionStore? = if usesDemoFixture {
            DemoSessionStore(transport: FakeTransport(matchEra: arguments.contains("-rail-fixture") ? "铁路时代" : "运河时代"))
        } else { nil }
        if let fixture = configuration.fixture { session?.setPlayerCount(fixture.playerCount) }
#endif
        let preferences = MotionPreferences()
        preferences.reduceMotion = configuration.reduceMotion
        preferences.colorAssistEnabled = configuration.colorAssist

        launchConfiguration = configuration
        self.environment = environment
#if DEBUG
        _session = State(initialValue: session)
#endif
        _preferences = State(initialValue: preferences)
        _realSession = State(initialValue: Self.makeRealSession(for: environment))
        _nearbyPersistenceState = State(initialValue: NearbyPersistenceState())
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if let realSession {
                RealSessionRootView(
                    store: realSession,
                    runsScriptHarness: environment.runsLocalScriptHarness
                )
                    .environment(preferences)
            } else if let session {
                RootView(
                    launchConfiguration: launchConfiguration,
                    fixtureSession: session,
                    nearbyPersistenceState: nearbyPersistenceState,
                    nearbyCatalogSource: environment.nearbyCatalogSource
                )
                    .environment(session).environment(preferences)
            } else {
                RootView(
                    launchConfiguration: launchConfiguration,
                    nearbyPersistenceState: nearbyPersistenceState,
                    nearbyCatalogSource: environment.nearbyCatalogSource
                )
                    .environment(preferences)
            }
#else
            if let realSession {
                RealSessionRootView(
                    store: realSession,
                    runsScriptHarness: environment.runsLocalScriptHarness
                )
                    .environment(preferences)
            } else {
                RootView(
                    launchConfiguration: launchConfiguration,
                    nearbyPersistenceState: nearbyPersistenceState
                )
                    .environment(preferences)
            }
#endif
        }
    }

    private static func makeRealSession(for environment: AppEnvironment) -> SessionViewStore? {
        switch environment.mode {
        case .production: return nil
#if DEBUG
        case .fixture: return nil
        case .localUIFixture:
            return .localUIFixture(
                presentationEraOverride: environment.localUIFixturePresentationEraOverride
            )
        case .localRecoveryUIFixture: return .localRecoveryUIFixture()
        case .localHarness(let harness):
            let catalog: GameCore.VerifiedGameDataCatalog
            do { catalog = try GameCore.GameDataLoader.loadBundledFixtureCatalog() }
            catch { return nil }
            let playerID = GameCore.PlayerID(rawValue: harness.role.rawValue)
            let configuration = SessionCoordinator.Configuration(
                protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion, roomID: harness.roomID,
                playerID: playerID, reconnectToken: .init(rawValue: "\(harness.roomID.rawValue)-\(playerID.rawValue)"),
                hostPlayerID: .init(rawValue: "host")
            )
            return SessionViewStore(coordinator: SessionCoordinator(
                configuration: configuration,
                transport: LocalNetworkTransport(serviceName: harness.roomID.rawValue),
                rulesMode: .verified(catalog)
            ), role: harness.role, roomID: harness.roomID, playerID: playerID,
               harnessPort: harness.port, fixtureGuest: nil)
#endif
        }
    }
}
