import OSLog
import SwiftUI

nonisolated enum MatchEntryPolicy {
    static func canEnterMatch(geometryReady: Bool) -> Bool {
        geometryReady
    }
}

struct RootView: View {
    @State private var path: [AppRoute]
    @State private var pendingMatchRoute: AppRoute?
    @State private var sceneReference = WindowSceneReference()
    @State private var isMatchOrientationAlertPresented = false

    private let logger = Logger(
        subsystem: "com.didi.prototype.IndustrialCityBirmingham",
        category: "Navigation"
    )
    private let launchConfiguration: DemoLaunchConfiguration
#if DEBUG
    private let fixtureSession: DemoSessionStore?
#endif
    private let nearbyPersistenceState: NearbyPersistenceState
    private let nearbyCatalogSource: NearbyCatalogSource

#if DEBUG
    init(
        launchConfiguration: DemoLaunchConfiguration = .standard,
        fixtureSession: DemoSessionStore? = nil,
        nearbyPersistenceState: NearbyPersistenceState = .init(),
        nearbyCatalogSource: NearbyCatalogSource = .packagedRules
    ) {
        self.launchConfiguration = launchConfiguration
        self.fixtureSession = fixtureSession
        self.nearbyPersistenceState = nearbyPersistenceState
        self.nearbyCatalogSource = nearbyCatalogSource
        _path = State(initialValue: launchConfiguration.fixture.map { [$0.initialRoute] } ?? [])
    }
#else
    init(
        launchConfiguration: DemoLaunchConfiguration = .standard,
        nearbyPersistenceState: NearbyPersistenceState = .init()
    ) {
        self.launchConfiguration = launchConfiguration
        self.nearbyPersistenceState = nearbyPersistenceState
        self.nearbyCatalogSource = .packagedRules
        _path = State(initialValue: [])
    }
#endif

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(onNavigate: navigate)
                .navigationDestination(for: AppRoute.self) { route in
                    destination(for: route)
                }
        }
        .background {
            WindowSceneProbe(onSceneChange: sceneDidChange)
                .frame(width: 0, height: 0)
        }
        .onChange(of: path) {
            applyCurrentOrientation()
        }
        .task(id: pendingMatchRoute) {
            await commitPendingMatchRoute()
        }
        .alert("无法进入对局", isPresented: $isMatchOrientationAlertPresented) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("设备未能切换到横屏。请保持全屏并再次点击“开始对局”。")
        }
    }

    private func navigate(to route: AppRoute) {
        guard case .match = route else {
            path.append(route)
            return
        }

        guard pendingMatchRoute == nil, path.last != route else { return }
        pendingMatchRoute = route
    }

    private func commitPendingMatchRoute() async {
        guard let route = pendingMatchRoute else { return }
        let sourcePath = path
        let geometryReady = await OrientationCoordinator.applyAndWait(
            .landscape,
            to: sceneReference.scene
        )

        guard !Task.isCancelled,
              pendingMatchRoute == route else { return }
        pendingMatchRoute = nil

        guard path == sourcePath else {
            applyCurrentOrientation()
            return
        }

        guard MatchEntryPolicy.canEnterMatch(geometryReady: geometryReady) else {
            logger.error("Keeping lobby visible because landscape geometry is unavailable")
            isMatchOrientationAlertPresented = true
            applyCurrentOrientation()
            return
        }
        guard path.last != route else { return }
        path.append(route)
    }

    private func sceneDidChange(to scene: UIWindowScene?) {
        let previousScene = sceneReference.scene
        guard previousScene !== scene else {
            applyCurrentOrientation()
            return
        }

        OrientationCoordinator.reset(scene: previousScene)
        sceneReference.scene = scene
        applyCurrentOrientation()
    }

    private func applyCurrentOrientation() {
        OrientationCoordinator.apply(
            OrientationPolicy.mask(for: path),
            to: sceneReference.scene
        )
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .home:
            HomeView(onNavigate: navigate)
        case .online:
#if DEBUG
            if let fixtureSession {
                OnlineRoomView(
                    initialDemoState: launchConfiguration.fixture == .versionMismatch ? .versionMismatch : .idle,
                    onNavigate: navigate
                ).environment(fixtureSession)
            } else {
                ContentUnavailableView("在线房间暂未开放", systemImage: "network.slash",
                                       description: Text("朋友测试阶段先使用附近离线房间。"))
            }
#else
            ContentUnavailableView("在线房间暂未开放", systemImage: "network.slash",
                                   description: Text("朋友测试阶段先使用附近离线房间。"))
#endif
        case .nearby:
#if DEBUG
            NearbyRoomView(
                persistenceState: nearbyPersistenceState,
                presentationMode: NearbyRoomPresentationMode.resolve(fixtureSessionAvailable: fixtureSession != nil),
                fixtureSession: fixtureSession,
                initialDemoState: launchConfiguration.fixture == .wirelessOff ? .wirelessOff : .searching,
                catalogSource: nearbyCatalogSource,
                onNavigate: navigate
            )
#else
            NearbyRoomView(
                persistenceState: nearbyPersistenceState,
                catalogSource: nearbyCatalogSource,
                onNavigate: navigate
            )
#endif
        case .lobby(let mode):
#if DEBUG
            if let fixtureSession {
                LobbyView(mode: mode, onNavigate: navigate).environment(fixtureSession)
            } else {
                ContentUnavailableView("演示大厅不可用", systemImage: "person.3.sequence.fill",
                                       description: Text("请从附近房间页创建或加入真实房间。"))
            }
#else
            ContentUnavailableView("演示大厅不可用", systemImage: "person.3.sequence.fill",
                                   description: Text("请从附近房间页创建或加入真实房间。"))
#endif
        case .rules:
            RulesSummaryView()
        case .settings:
            SettingsView()
        case .gallery:
#if DEBUG
            UIGalleryView()
#else
            ContentUnavailableView("组件展廊仅限调试版本", systemImage: "wrench.and.screwdriver")
#endif
        case .match(let playerCount):
#if DEBUG
            if let fixtureSession {
                MatchView(
                    playerCount: playerCount,
                    initialState: launchConfiguration.matchInitialState
                ).environment(fixtureSession)
            } else {
                ContentUnavailableView("演示对局不可用", systemImage: "rectangle.slash",
                                       description: Text("真实对局会从附近房间大厅进入。"))
            }
#else
            ContentUnavailableView("演示对局不可用", systemImage: "rectangle.slash",
                                   description: Text("真实对局会从附近房间大厅进入。"))
#endif
        }
    }

}
