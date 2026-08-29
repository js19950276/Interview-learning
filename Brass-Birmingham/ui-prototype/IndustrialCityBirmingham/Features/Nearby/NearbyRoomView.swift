import OSLog
import SwiftUI
import UIKit

nonisolated enum NearbyCatalogSource: Equatable, Sendable {
    case packagedRules
#if DEBUG
    case debugFixture
#endif

    func load() throws -> GameCore.VerifiedGameDataCatalog {
        switch self {
        case .packagedRules:
            try GameCore.GameDataLoader.loadBundledSetupCatalog()
#if DEBUG
        case .debugFixture:
            try GameCore.GameDataLoader.loadBundledFixtureCatalog()
#endif
        }
    }
}

nonisolated enum NearbyRoomPresentationMode: Equatable, Sendable {
    case production
#if DEBUG
    case fixture

    static func resolve(fixtureSessionAvailable: Bool) -> Self {
        fixtureSessionAvailable ? .fixture : .production
    }
#endif
}

@MainActor
struct NearbyProductionState {
    private(set) var browseState: NearbyBrowseState = .searching
    private(set) var recoverableHostRooms: [RecoverableSessionReference] = []
    private(set) var catalog: GameCore.VerifiedGameDataCatalog?
    private(set) var fatalIssue: NearbyPreflightIssue?
    private(set) var operationalIssue: NearbyPreflightIssue?

    var canStartBrowsing: Bool {
        fatalIssue == nil && operationalIssue == nil && catalog != nil
    }
    var canRetryBrowsing: Bool { fatalIssue == nil && catalog != nil }
    var interactionsDisabled: Bool { fatalIssue != nil || catalog == nil }

    func loadingRecoveryPrerequisites(
        catalogLoader: () throws -> GameCore.VerifiedGameDataCatalog,
        roomsLoader: (GameCore.VerifiedGameDataCatalog) async throws -> [RecoverableSessionReference]
    ) async -> Self {
        guard fatalIssue == nil else { return self }
        var updated = self
        let loadedCatalog: GameCore.VerifiedGameDataCatalog
        do {
            loadedCatalog = try catalogLoader()
        } catch {
            updated.latchFatal(NearbyPreflight.issue(for: error))
            return updated
        }
        updated.catalog = loadedCatalog
        do {
            let rooms = try await roomsLoader(loadedCatalog)
            updated.recoverableHostRooms = rooms
        } catch {
            updated.receiveOperationalFailure(NearbyPreflight.issue(for: error))
        }
        return updated
    }

    mutating func receiveBrowserState(_ state: NearbyBrowseState) {
        guard fatalIssue == nil, operationalIssue == nil else { return }
        browseState = state
    }

    mutating func receiveOperationalFailure(_ issue: NearbyPreflightIssue) {
        guard fatalIssue == nil else { return }
        operationalIssue = issue
        browseState = .failed(issue)
    }

    mutating func restartSearching() {
        guard fatalIssue == nil, catalog != nil else { return }
        operationalIssue = nil
        browseState = .searching
    }

    private mutating func latchFatal(_ issue: NearbyPreflightIssue) {
        fatalIssue = issue
        operationalIssue = nil
        catalog = nil
        recoverableHostRooms = []
        browseState = .failed(issue)
    }
}

struct NearbyRoomView: View {
    let persistenceState: NearbyPersistenceState
#if DEBUG
    let presentationMode: NearbyRoomPresentationMode
    let fixtureSession: DemoSessionStore?
    let initialDemoState: NearbyDemoState
#endif
    let catalogSource: NearbyCatalogSource
    let onNavigate: (AppRoute) -> Void

#if DEBUG
    init(
        persistenceState: NearbyPersistenceState,
        presentationMode: NearbyRoomPresentationMode = .production,
        fixtureSession: DemoSessionStore? = nil,
        initialDemoState: NearbyDemoState = .searching,
        catalogSource: NearbyCatalogSource = .packagedRules,
        onNavigate: @escaping (AppRoute) -> Void
    ) {
        self.persistenceState = persistenceState
        self.presentationMode = presentationMode
        self.fixtureSession = fixtureSession
        self.initialDemoState = initialDemoState
        self.catalogSource = catalogSource
        self.onNavigate = onNavigate
    }
#else
    init(
        persistenceState: NearbyPersistenceState,
        catalogSource: NearbyCatalogSource = .packagedRules,
        onNavigate: @escaping (AppRoute) -> Void
    ) {
        self.persistenceState = persistenceState
        self.catalogSource = catalogSource
        self.onNavigate = onNavigate
    }
#endif

    var persistenceTrackerIdentity: ObjectIdentifier {
        persistenceState.persistenceFactory.recoveryTrackerIdentity
    }

    @ViewBuilder
    var body: some View {
#if DEBUG
        switch presentationMode {
        case .production:
            ProductionNearbyRoomView(
                persistenceState: persistenceState,
                catalogSource: catalogSource
            )
        case .fixture:
            if let fixtureSession {
                FixtureNearbyRoomView(initialDemoState: initialDemoState, onNavigate: onNavigate)
                    .environment(fixtureSession)
            } else {
                ContentUnavailableView("演示环境不可用", systemImage: "wrench.and.screwdriver",
                                       description: Text("请重新从测试入口打开。"))
            }
        }
#else
        ProductionNearbyRoomView(
            persistenceState: persistenceState,
            catalogSource: catalogSource
        )
#endif
    }
}

private struct ProductionNearbyRoomView: View {
    private struct ActiveSession: Identifiable {
        let id = UUID()
        let store: SessionViewStore
    }

    @State private var browser: BonjourPeerBrowser?
    @State private var productionState = NearbyProductionState()
    @State private var activeSession: ActiveSession?
    @State private var isJoining = false
    let persistenceState: NearbyPersistenceState
    let catalogSource: NearbyCatalogSource
    private var persistenceFactory: SessionPersistenceFactory { persistenceState.persistenceFactory }
    private var browseState: NearbyBrowseState { productionState.browseState }
    private var recoverableHostRooms: [RecoverableSessionReference] { productionState.recoverableHostRooms }

    var body: some View {
        ZStack {
            nearbyBackground

            ScrollView {
                VStack(alignment: .leading, spacing: BrassSpacing.large) {
                    VStack(alignment: .leading, spacing: BrassSpacing.small) {
                        Text("附近离线房间")
                            .font(BrassTypography.title)
                        Text("不需要互联网或服务器。飞行模式可以保持开启；如果系统关闭了 Wi-Fi，请在控制中心重新打开 Wi-Fi。")
                            .font(BrassTypography.body)
                            .foregroundStyle(BrassColor.paper.color.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    statePanel
                    roomList
                    recoveryList

                    Button {
                        createRoom()
                    } label: {
                        Label("创建附近房间", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrassPrimaryButtonStyle())
                    .disabled(isJoining || productionState.interactionsDisabled)
                    .accessibilityIdentifier("nearby.create")

                    Button {
                        restartBrowsing()
                    } label: {
                        Label("重新搜索", systemImage: "arrow.clockwise")
                            .font(BrassTypography.label)
                            .foregroundStyle(BrassColor.paper.color)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(BrassColor.fog.color.opacity(0.28))
                            .clipShape(RoundedRectangle(cornerRadius: BrassRadius.card))
                    }
                    .disabled(isJoining || !productionState.canRetryBrowsing)
                    .accessibilityIdentifier("nearby.search")

                    Text("模拟器只能验证界面与状态机，不能证明真机的本地网络授权或点对点连接。")
                        .font(.footnote)
                        .foregroundStyle(BrassColor.paper.color.opacity(0.62))
                }
                .foregroundStyle(BrassColor.paper.color)
                .brassPanel()
                .padding(BrassSpacing.large)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("snapshot.ready")
        .navigationTitle("附近")
        .task {
            await loadRecoverableHostRooms()
            if productionState.canStartBrowsing { await startBrowsing() }
        }
        .onDisappear { Task { await stopBrowsing() } }
        .fullScreenCover(item: $activeSession) { session in
            NearbySessionContainer(store: session.store)
        }
    }

    private var nearbyBackground: some View {
        LinearGradient(
            colors: [BrassColor.coal.color, BrassColor.iron.color.opacity(0.8), BrassColor.fog.color.opacity(0.4)],
            startPoint: .topTrailing,
            endPoint: .bottomLeading
        )
        .ignoresSafeArea()
    }

    private var statePanel: some View {
        HStack(alignment: .top, spacing: BrassSpacing.medium) {
            if browseState == .searching || isJoining {
                ProgressView()
                    .tint(BrassColor.brass.color)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: stateSymbol)
                    .font(.title2)
                    .foregroundStyle(BrassColor.brass.color)
                    .frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: BrassSpacing.xSmall) {
                Text(isJoining ? "正在加入房间" : stateTitle)
                    .font(BrassTypography.label)
                Text(isJoining ? "正在建立附近点对点连接，请保持两台设备靠近。" : stateRecovery)
                    .font(BrassTypography.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BrassSpacing.medium)
        .background(BrassColor.coal.color.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: BrassRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nearby.preflight")
    }

    @ViewBuilder
    private var roomList: some View {
        if case let .found(rooms) = browseState {
            VStack(alignment: .leading, spacing: BrassSpacing.small) {
                Text("可加入的房间")
                    .font(BrassTypography.label)
                ForEach(rooms) { room in
                    Button {
                        join(room)
                    } label: {
                        HStack(spacing: BrassSpacing.medium) {
                            Image(systemName: "person.3.fill")
                                .foregroundStyle(BrassColor.brass.color)
                            VStack(alignment: .leading, spacing: BrassSpacing.xSmall) {
                                Text(room.serviceName)
                                    .font(BrassTypography.label)
                                Text("点按加入 · 2–4 人")
                                    .font(BrassTypography.body)
                                    .foregroundStyle(BrassColor.paper.color.opacity(0.72))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .foregroundStyle(BrassColor.paper.color)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .padding(.horizontal, BrassSpacing.medium)
                        .background(BrassColor.coal.color.opacity(0.42))
                        .clipShape(RoundedRectangle(cornerRadius: BrassRadius.card))
                    }
                    .disabled(isJoining || productionState.interactionsDisabled)
                    .accessibilityIdentifier("nearby.room.\(room.id)")
                }
            }
        }
    }

    @ViewBuilder
    private var recoveryList: some View {
        if !recoverableHostRooms.isEmpty {
            VStack(alignment: .leading, spacing: BrassSpacing.small) {
                Text("恢复本机房主对局")
                    .font(BrassTypography.label)
                ForEach(recoverableHostRooms) { reference in
                    Button {
                        restoreRoom(reference)
                    } label: {
                        Label("恢复 \(reference.roomID.rawValue)", systemImage: "arrow.clockwise.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(BrassPrimaryButtonStyle())
                    .disabled(isJoining || productionState.interactionsDisabled)
                    .accessibilityIdentifier("nearby.restore.\(reference.roomID.rawValue)")
                }
            }
        }
    }

    private var stateSymbol: String {
        switch browseState {
        case .searching: "dot.radiowaves.left.and.right"
        case .found: "person.3.fill"
        case .empty: "person.slash.fill"
        case let .failed(issue): issue == .permissionDenied ? "hand.raised.fill" : "wifi.exclamationmark"
        }
    }

    private var stateTitle: String {
        switch browseState {
        case .searching: "正在搜索附近房间"
        case let .found(rooms): "发现 \(rooms.count) 个附近房间"
        case .empty: NearbyPreflightIssue.noRooms.title
        case let .failed(issue): issue.title
        }
    }

    private var stateRecovery: String {
        switch browseState {
        case .searching: "让房主保持创建页面打开，并将设备放在同一空间。"
        case .found: "选择房间加入；房主稍后可在真实大厅中开始对局。"
        case .empty: NearbyPreflightIssue.noRooms.recoveryMessage
        case let .failed(issue): issue.recoveryMessage
        }
    }

    @MainActor
    private func startBrowsing() async {
        guard productionState.canStartBrowsing, browser == nil else { return }
        let browser = BonjourPeerBrowser()
        self.browser = browser
        let states = browser.states
        await browser.start()
        for await state in states {
            guard !Task.isCancelled else { return }
            productionState.receiveBrowserState(state)
        }
    }

    @MainActor
    private func stopBrowsing() async {
        await browser?.cancel()
        browser = nil
    }

    private func restartBrowsing() {
        Task { @MainActor in
            await stopBrowsing()
            productionState.restartSearching()
            await startBrowsing()
        }
    }

    @MainActor
    private func loadRecoverableHostRooms() async {
        let current = productionState
        productionState = await current.loadingRecoveryPrerequisites(
            catalogLoader: { try catalogSource.load() },
            roomsLoader: { catalog in
                try await persistenceFactory.recoverableHostRooms(catalog: catalog)
            }
        )
    }

    private func createRoom() {
        guard !isJoining, let catalog = productionState.catalog else { return }
        isJoining = true
        Task { @MainActor in
            do {
                let roomID = GameCore.RoomID(rawValue: Self.makeRoomName())
                let store = try await SessionViewStore.nearbyHost(
                    roomID: roomID,
                    identity: Self.deviceIdentity(),
                    persistenceFactory: persistenceFactory,
                    catalog: catalog
                )
                if let issue = await store.connect() {
                    productionState.receiveOperationalFailure(issue)
                    await store.disconnect()
                } else {
                    activeSession = ActiveSession(store: store)
                }
            } catch {
                Logger(
                    subsystem: "com.didi.prototype.IndustrialCityBirmingham",
                    category: "NearbyRoom"
                ).error("Create room failed: \(String(reflecting: error), privacy: .public)")
                productionState.receiveOperationalFailure(NearbyPreflight.issue(for: error))
            }
            isJoining = false
        }
    }

    private func join(_ room: NearbyRoom) {
        guard !isJoining, let catalog = productionState.catalog else { return }
        isJoining = true
        Task { @MainActor in
            do {
                let store = try await SessionViewStore.nearbyGuest(
                    room: room,
                    identity: Self.deviceIdentity(),
                    persistenceFactory: persistenceFactory,
                    catalog: catalog
                )
                if let issue = await store.connect() {
                    productionState.receiveOperationalFailure(issue)
                    await store.disconnect()
                } else {
                    activeSession = ActiveSession(store: store)
                }
            } catch {
                productionState.receiveOperationalFailure(NearbyPreflight.issue(for: error))
            }
            isJoining = false
        }
    }

    private func restoreRoom(_ reference: RecoverableSessionReference) {
        guard !isJoining, let catalog = productionState.catalog else { return }
        isJoining = true
        Task { @MainActor in
            do {
                let store = try await NearbyHostRecoveryRoute.makeStore(
                    reference: reference,
                    identity: Self.deviceIdentity(),
                    persistenceFactory: persistenceFactory,
                    transport: NearbyTransport(),
                    catalog: catalog
                )
                if let issue = await store.connect() {
                    productionState.receiveOperationalFailure(issue)
                    await store.disconnect()
                } else {
                    activeSession = ActiveSession(store: store)
                }
            } catch {
                productionState.receiveOperationalFailure(NearbyPreflight.issue(for: error))
            }
            isJoining = false
        }
    }

    private static func makeRoomName() -> String {
        "BRASS-\(String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)))"
    }

    private static func deviceIdentity() -> NearbySessionIdentity {
        NearbySessionIdentity.make(deviceID: UIDevice.current.identifierForVendor)
    }
}

private struct NearbySessionContainer: View {
    @Environment(\.dismiss) private var dismiss
    let store: SessionViewStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            RealSessionRootView(store: store, runsScriptHarness: false)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(BrassColor.paper.color)
                    .frame(width: 44, height: 44)
                    .background(BrassColor.coal.color.opacity(0.84), in: Circle())
            }
            .padding(BrassSpacing.medium)
            .accessibilityLabel("退出附近房间")
        }
    }
}

#if DEBUG
private struct FixtureNearbyRoomView: View {
    @Environment(DemoSessionStore.self) private var store
    @State private var demoState: NearbyDemoState
    @State private var lobbyRequestID: UUID?

    let onNavigate: (AppRoute) -> Void

    init(initialDemoState: NearbyDemoState, onNavigate: @escaping (AppRoute) -> Void) {
        _demoState = State(initialValue: initialDemoState)
        self.onNavigate = onNavigate
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [BrassColor.coal.color, BrassColor.iron.color.opacity(0.8), BrassColor.fog.color.opacity(0.4)],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: BrassSpacing.large) {
                    Text("附近离线房间").font(BrassTypography.title)
                    Text("这是无需服务器的确定性演示，不会启动附近设备扫描。")
                        .font(BrassTypography.body)
                        .foregroundStyle(BrassColor.paper.color.opacity(0.78))

                    Picker("演示状态", selection: $demoState) {
                        ForEach(NearbyDemoState.allCases) { state in
                            Image(systemName: state.symbol).accessibilityLabel(state.pickerTitle).tag(state)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.extraLarge)
                    .accessibilityIdentifier("nearby.preflight.selector")

                    statePanel

                    Button { enterLobby() } label: {
                        loadingLabel(title: "创建附近演示房间").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrassPrimaryButtonStyle())
                    .disabled(!canEnterLobby)
                    .accessibilityIdentifier("nearby.create")

                    Button { enterLobby() } label: {
                        Label("搜索并进入演示房间", systemImage: "magnifyingglass")
                            .font(BrassTypography.label)
                            .foregroundStyle(BrassColor.paper.color)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(isLoading ? BrassColor.coal.color.opacity(0.82) : BrassColor.fog.color.opacity(0.28))
                            .clipShape(RoundedRectangle(cornerRadius: BrassRadius.card))
                    }
                    .disabled(!canEnterLobby)
                    .accessibilityIdentifier("nearby.search")

                    if let message = store.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(BrassTypography.body)
                    }
                }
                .foregroundStyle(BrassColor.paper.color)
                .brassPanel()
                .padding(BrassSpacing.large)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("snapshot.ready")
        .navigationTitle("附近")
        .task(id: lobbyRequestID) { await performLobbyRequest() }
    }

    private var statePanel: some View {
        HStack(alignment: .top, spacing: BrassSpacing.medium) {
            Image(systemName: demoState.symbol)
                .font(.title2).foregroundStyle(BrassColor.brass.color).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: BrassSpacing.xSmall) {
                Text(demoState.title).font(BrassTypography.label)
                Text(demoState.recovery).font(BrassTypography.body).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BrassSpacing.medium)
        .background(BrassColor.coal.color.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: BrassRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nearby.preflight")
    }

    @ViewBuilder
    private func loadingLabel(title: String) -> some View {
        if isLoading {
            HStack(spacing: BrassSpacing.small) { ProgressView(); Text("正在准备大厅") }
        } else { Text(title) }
    }

    private func enterLobby() {
        guard !isLoading else { return }
        lobbyRequestID = UUID()
    }

    private func performLobbyRequest() async {
        guard let requestID = lobbyRequestID else { return }
        let loadedLobby = await store.loadLobby(mode: .nearby)
        guard requestID == lobbyRequestID else { return }
        if loadedLobby != nil, !Task.isCancelled { onNavigate(.lobby(.nearby)) }
        lobbyRequestID = nil
    }

    private var isLoading: Bool { lobbyRequestID != nil }
    private var canEnterLobby: Bool {
        !isLoading && demoState != .wirelessOff && demoState != .permissionDenied
    }
}

enum NearbyDemoState: String, CaseIterable, Identifiable {
    case searching
    case found
    case empty
    case wirelessOff
    case permissionDenied

    var id: String { rawValue }

    var pickerTitle: String {
        switch self {
        case .searching: "搜索"
        case .found: "已发现"
        case .empty: "无房间"
        case .wirelessOff: "无线"
        case .permissionDenied: "权限"
        }
    }

    var symbol: String {
        switch self {
        case .searching: "dot.radiowaves.left.and.right"
        case .found: "person.3.fill"
        case .empty: "person.slash.fill"
        case .wirelessOff: "antenna.radiowaves.left.and.right.slash"
        case .permissionDenied: "hand.raised.fill"
        }
    }

    var title: String {
        switch self {
        case .searching: "正在演示搜索附近房间"
        case .found: "发现可加入的演示房间"
        case .empty: "附近没有开放房间"
        case .wirelessOff: "无线连接已关闭"
        case .permissionDenied: "附近交互权限未授权"
        }
    }

    var recovery: String {
        switch self {
        case .searching: "让房主保持创建页面打开，并将设备放在同一房间内。"
        case .found: "确认屏幕上的房主与玩家数量，再选择搜索按钮进入大厅。"
        case .empty: "请其中一台设备先创建附近房间，然后在其他设备上重新进入此页。"
        case .wirelessOff: "飞行模式可以保持开启；如果系统关闭了 Wi-Fi，请重新打开 Wi-Fi。"
        case .permissionDenied: "前往系统设置，为本应用允许本地网络访问。"
        }
    }
}
#endif
