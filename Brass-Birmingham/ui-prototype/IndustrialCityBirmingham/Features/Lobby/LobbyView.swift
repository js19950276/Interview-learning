import SwiftUI

struct RealSessionRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: SessionViewStore
    let runsScriptHarness: Bool

    var body: some View {
        ZStack {
            if store.snapshot != nil {
                RealMatchView(store: store)
            } else {
                realLobby
            }
        }
        .task {
            await withTaskCancellationHandler {
#if DEBUG
                if runsScriptHarness { await store.runScriptHarness() }
                else { _ = await store.connect() }
#else
                _ = await store.connect()
#endif
            } onCancel: {
                Task { await store.disconnect() }
            }
        }
        .onDisappear { Task { await store.disconnect() } }
        .onChange(of: scenePhase) { _, phase in
            Task { await store.handleScenePhase(phase) }
        }
    }

    private var realLobby: some View {
        ZStack {
            LinearGradient(colors: [BrassColor.coal.color, BrassColor.iron.color],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BrassSpacing.large) {
                Text("附近真实房间").font(BrassTypography.title)
                Label(store.roomID.rawValue, systemImage: "number")
                    .accessibilityIdentifier("real.room")
                ForEach(store.players, id: \.self) { player in
                    Label("\(player.rawValue) · \(store.readyPlayerIDs.contains(player) ? "已准备" : "未准备")",
                          systemImage: player == store.hostPlayerID ? "crown.fill" : "person.fill")
                }
                Button(store.isReady ? "取消准备" : "准备") {
                    Task { await store.setReady(!store.isReady) }
                }
                .buttonStyle(BrassPrimaryButtonStyle())
                .accessibilityIdentifier("real.ready")
                Button("开始比赛") { Task { await store.startGame() } }
                    .buttonStyle(BrassPrimaryButtonStyle()).disabled(!store.canStart)
                    .accessibilityIdentifier("real.start")
                if let error = store.errorMessage { Text(error).foregroundStyle(BrassColor.danger.color) }
            }
            .foregroundStyle(BrassColor.paper.color).brassPanel().padding(BrassSpacing.large)
        }
    }
}

#if DEBUG
struct LobbyView: View {
    @Environment(DemoSessionStore.self) private var store
    @State private var isReloading = false
    @State private var matchRequestID: UUID?

    let mode: ConnectionMode
    let onNavigate: (AppRoute) -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [BrassColor.coal.color, BrassColor.iron.color.opacity(0.82), BrassColor.fog.color.opacity(0.38)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: BrassSpacing.large) {
                    header
                    playerCountPicker
                    playerList
                    errorMessage
                    startButton
                }
                .foregroundStyle(BrassColor.paper.color)
                .brassPanel()
                .padding(BrassSpacing.large)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(snapshotReadinessIdentifier)
        .navigationTitle("大厅")
        .task(id: lobbyLoadKey) {
            await loadLobby(for: lobbyLoadKey)
        }
        .task(id: matchRequestID) {
            await performMatchRequest()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: BrassSpacing.small) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: BrassSpacing.small) {
                    lobbyTitle
                    modeBadge
                }
                VStack(alignment: .leading, spacing: BrassSpacing.small) {
                    lobbyTitle
                    modeBadge
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: BrassSpacing.large) {
                    roomCodeLabel
                    rulesVersionLabel
                }
                VStack(alignment: .leading, spacing: BrassSpacing.small) {
                    roomCodeLabel
                    rulesVersionLabel
                }
            }
            .font(BrassTypography.number)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lobbyTitle: some View {
        Text(mode == .online ? "在线大厅" : "附近大厅")
            .font(BrassTypography.title)
    }

    private var modeBadge: some View {
        Text(mode == .online ? "ONLINE" : "NEARBY")
            .font(BrassTypography.label)
            .foregroundStyle(BrassColor.coal.color)
            .padding(.horizontal, BrassSpacing.small)
            .padding(.vertical, BrassSpacing.xSmall)
            .background(BrassColor.brass.color)
            .clipShape(Capsule())
    }

    private var roomCodeLabel: some View {
        Label(store.lobby?.roomCode ?? "准备中", systemImage: "number")
    }

    private var rulesVersionLabel: some View {
        Label("v2018.11", systemImage: "book.closed.fill")
    }

    private var playerCountPicker: some View {
        VStack(alignment: .leading, spacing: BrassSpacing.small) {
            Text("玩家人数")
                .font(BrassTypography.label)

            Picker("玩家人数", selection: Binding(
                get: { store.playerCount },
                set: { _ = store.setPlayerCount($0) }
            )) {
                ForEach(2...4, id: \.self) { count in
                    Text("\(count) 人").tag(count)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.extraLarge)
            .disabled(isReloading || isStarting)
            .accessibilityIdentifier("lobby.playerCount.selector")
        }
    }

    @ViewBuilder
    private var playerList: some View {
        if isReloading {
            HStack(spacing: BrassSpacing.small) {
                ProgressView()
                Text("正在装配玩家席位")
                    .font(BrassTypography.body)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
        } else if let lobby = visibleLobby {
            VStack(spacing: BrassSpacing.small) {
                ForEach(lobby.players) { player in
                    playerRow(player)
                }
            }
        } else {
            Label("席位尚未加载，请查看下方错误提示。", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(BrassTypography.body)
                .frame(maxWidth: .infinity, minHeight: 88)
        }
    }

    private func playerRow(_ player: PlayerSummary) -> some View {
        HStack(alignment: .center, spacing: BrassSpacing.medium) {
            Image(systemName: player.color.symbol)
                .font(.title2)
                .foregroundStyle(playerColor(player.color))
                .frame(width: 32, height: 44)

            VStack(alignment: .leading, spacing: BrassSpacing.small) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: BrassSpacing.small) {
                        Text(player.name)
                        if player.isHost {
                            Label("房主", systemImage: "crown.fill")
                        }
                    }
                    VStack(alignment: .leading, spacing: BrassSpacing.xSmall) {
                        Text(player.name)
                        if player.isHost {
                            Label("房主", systemImage: "crown.fill")
                        }
                    }
                }
                .font(BrassTypography.label)

                Text("顺位 \(player.order) · 已花费 £\(player.spent)")
                    .font(BrassTypography.number)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: BrassSpacing.medium) {
                        readyLabel(player)
                        connectionLabel(player)
                    }
                    VStack(alignment: .leading, spacing: BrassSpacing.xSmall) {
                        readyLabel(player)
                        connectionLabel(player)
                    }
                }
                .font(BrassTypography.label)
            }
        }
        .padding(.horizontal, BrassSpacing.medium)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(BrassColor.coal.color.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: BrassRadius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(playerAccessibilityLabel(player))
        .accessibilityIdentifier("lobby.player")
    }

    private func readyLabel(_ player: PlayerSummary) -> some View {
        Label(player.isReady ? "已准备" : "未准备", systemImage: player.isReady ? "checkmark.circle.fill" : "circle")
    }

    private func connectionLabel(_ player: PlayerSummary) -> some View {
        Label(player.isConnected ? "已连接" : "已断开", systemImage: player.isConnected ? "link.circle.fill" : "link.badge.plus")
    }

    private var startButton: some View {
        Button {
            startMatch()
        } label: {
            if isStarting {
                HStack(spacing: BrassSpacing.small) {
                    ProgressView()
                    Text("正在开始")
                }
                .frame(maxWidth: .infinity)
            } else {
                Text("开始比赛")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(BrassPrimaryButtonStyle())
        .disabled(!canStart)
        .accessibilityIdentifier("lobby.start")
    }

    @ViewBuilder
    private var errorMessage: some View {
        if let message = store.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(BrassTypography.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var visibleLobby: LobbyState? {
        guard let lobby = store.lobby,
              lobby.mode == mode,
              lobby.players.count == store.playerCount else { return nil }
        return lobby
    }

    private var snapshotReadinessIdentifier: String {
        visibleLobby == nil || isReloading ? "lobby.loading" : "snapshot.ready"
    }

    private var canStart: Bool {
        guard let lobby = visibleLobby else { return false }
        return !isReloading && !isStarting && LobbyStartPolicy.canStart(players: lobby.players)
    }

    private var lobbyLoadKey: String {
        "\(mode.rawValue)-\(store.playerCount)"
    }

    private func loadLobby(for requestKey: String) async {
        guard visibleLobby == nil else {
            isReloading = false
            return
        }
        isReloading = true
        _ = await store.loadLobby(mode: mode)
        if requestKey == lobbyLoadKey {
            isReloading = false
        }
    }

    private func startMatch() {
        guard canStart else { return }
        matchRequestID = UUID()
    }

    private func performMatchRequest() async {
        guard let requestID = matchRequestID else { return }
        let loadedMatch = await store.loadMatch()
        guard requestID == matchRequestID else { return }

        if loadedMatch != nil, !Task.isCancelled {
            onNavigate(.match(playerCount: store.playerCount))
        }
        matchRequestID = nil
    }

    private var isStarting: Bool {
        matchRequestID != nil
    }

    private func playerAccessibilityLabel(_ player: PlayerSummary) -> String {
        let host = player.isHost ? "房主" : "玩家"
        let ready = player.isReady ? "已准备" : "未准备"
        let connected = player.isConnected ? "已连接" : "已断开"
        return "\(player.name)，\(playerColorDescription(player.color))，\(host)，顺位 \(player.order)，已花费 £\(player.spent)，\(ready)，\(connected)"
    }

    private func playerColorDescription(_ color: PlayerColor) -> String {
        switch color {
        case .amber: "琥珀色，菱形标记"
        case .crimson: "绯红色，三角形标记"
        case .teal: "青绿色，圆形标记"
        case .violet: "紫罗兰色，方形标记"
        }
    }

    private func playerColor(_ color: PlayerColor) -> Color {
        switch color {
        case .amber: BrassColor.brass.color
        case .crimson: BrassColor.danger.color
        case .teal: Color.teal
        case .violet: Color.purple
        }
    }
}

nonisolated enum LobbyStartPolicy {
    static func canStart(players: [PlayerSummary]) -> Bool {
        !players.isEmpty && players.allSatisfy { $0.isReady && $0.isConnected }
    }
}
#endif
