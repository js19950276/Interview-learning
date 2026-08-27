#if DEBUG
import SwiftUI

struct OnlineRoomView: View {
    @Environment(DemoSessionStore.self) private var store
    @State private var demoState: OnlineDemoState
    @State private var roomCode = ""
    @State private var lobbyRequestID: UUID?

    let onNavigate: (AppRoute) -> Void

    init(
        initialDemoState: OnlineDemoState = .idle,
        onNavigate: @escaping (AppRoute) -> Void
    ) {
        _demoState = State(initialValue: initialDemoState)
        self.onNavigate = onNavigate
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [BrassColor.coal.color, BrassColor.iron.color.opacity(0.78), BrassColor.fog.color.opacity(0.42)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: BrassSpacing.large) {
                    Text("在线房间")
                        .font(BrassTypography.title)

                    Text("这是确定性的本地流程演示，不会连接真实服务器。")
                        .font(BrassTypography.body)
                        .foregroundStyle(BrassColor.paper.color.opacity(0.78))

                    Picker("演示状态", selection: $demoState) {
                        ForEach(OnlineDemoState.allCases) { state in
                            Image(systemName: state.symbol)
                                .accessibilityLabel(state.pickerTitle)
                                .tag(state)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.extraLarge)
                    .accessibilityIdentifier("online.state.selector")

                    statePanel

                    Button {
                        requestLobby()
                    } label: {
                        loadingLabel(title: "创建演示房间")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrassPrimaryButtonStyle())
                    .disabled(!canCreate)
                    .accessibilityIdentifier("online.create")

                    VStack(alignment: .leading, spacing: BrassSpacing.small) {
                        Text("加入房间")
                            .font(BrassTypography.label)

                        TextField("输入 6 位房间码", text: $roomCode)
                            .textInputAutocapitalization(.characters)
                            .keyboardType(.asciiCapable)
                            .autocorrectionDisabled()
                            .padding(.horizontal, BrassSpacing.medium)
                            .frame(minHeight: 44)
                            .background(BrassColor.paper.color.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: BrassRadius.card))
                            .accessibilityIdentifier("online.join.code")
                            .disabled(!canUseRoomCode)
                            .onChange(of: roomCode) { _, newValue in
                                let normalized = RoomCodePolicy.normalized(newValue)
                                if roomCode != normalized {
                                    roomCode = normalized
                                }
                            }

                        Button("使用房间码进入演示大厅") {
                            requestLobby()
                        }
                        .font(BrassTypography.label)
                        .foregroundStyle(BrassColor.paper.color)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(canJoin ? BrassColor.fog.color.opacity(0.28) : BrassColor.coal.color.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: BrassRadius.card))
                        .overlay {
                            RoundedRectangle(cornerRadius: BrassRadius.card)
                                .stroke(BrassColor.paper.color.opacity(canJoin ? 0.2 : 0.48), lineWidth: 1)
                        }
                        .disabled(!canJoin)
                        .accessibilityIdentifier("online.join")
                    }

                    errorMessage
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
        .navigationTitle("在线")
        .task(id: lobbyRequestID) {
            await performLobbyRequest()
        }
    }

    private var statePanel: some View {
        HStack(alignment: .top, spacing: BrassSpacing.medium) {
            Image(systemName: demoState.symbol)
                .font(.title2)
                .foregroundStyle(BrassColor.brass.color)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: BrassSpacing.xSmall) {
                Text(demoState.title)
                    .font(BrassTypography.label)
                Text(demoState.recovery)
                    .font(BrassTypography.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BrassSpacing.medium)
        .background(BrassColor.coal.color.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: BrassRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("online.state")
    }

    @ViewBuilder
    private func loadingLabel(title: String) -> some View {
        if isLoading {
            HStack(spacing: BrassSpacing.small) {
                ProgressView()
                Text("正在准备大厅")
            }
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private var errorMessage: some View {
        if let message = store.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(BrassTypography.body)
                .foregroundStyle(BrassColor.paper.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func requestLobby() {
        guard !isLoading else { return }
        lobbyRequestID = UUID()
    }

    private func performLobbyRequest() async {
        guard let requestID = lobbyRequestID else { return }
        let loadedLobby = await store.loadLobby(mode: .online)
        guard requestID == lobbyRequestID else { return }

        if loadedLobby != nil, !Task.isCancelled {
            onNavigate(.lobby(.online))
        }
        lobbyRequestID = nil
    }

    private var isLoading: Bool {
        lobbyRequestID != nil
    }

    private var canJoin: Bool {
        RoomCodePolicy.isValid(roomCode) && canUseRoomCode
    }

    private var canCreate: Bool { demoState == .idle && !isLoading }

    private var canUseRoomCode: Bool { demoState == .idle && !isLoading }
}

nonisolated enum RoomCodePolicy {
    static func normalized(_ input: String) -> String {
        let uppercase = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let allowedScalars = uppercase.unicodeScalars.filter(isAllowed)
        return String(allowedScalars.prefix(6).map { Character(String($0)) })
    }

    static func isValid(_ input: String) -> Bool {
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return candidate.unicodeScalars.count == 6 && candidate.unicodeScalars.allSatisfy(isAllowed)
    }

    private static func isAllowed(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(scalar.value) || (48...57).contains(scalar.value)
    }
}

enum OnlineDemoState: String, CaseIterable, Identifiable {
    case idle
    case connecting
    case roomNotFound
    case offline
    case versionMismatch

    var id: String { rawValue }

    var pickerTitle: String {
        switch self {
        case .idle: "待机"
        case .connecting: "连接"
        case .roomNotFound: "无房间"
        case .offline: "离线"
        case .versionMismatch: "版本"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "network"
        case .connecting: "arrow.triangle.2.circlepath"
        case .roomNotFound: "door.left.hand.closed"
        case .offline: "wifi.slash"
        case .versionMismatch: "arrow.down.app.fill"
        }
    }

    var title: String {
        switch self {
        case .idle: "等待创建或加入"
        case .connecting: "正在建立演示连接"
        case .roomNotFound: "没有找到该房间"
        case .offline: "设备当前离线"
        case .versionMismatch: "规则版本不一致"
        }
    }

    var recovery: String {
        switch self {
        case .idle: "创建新房间，或向房主确认六位房间码后输入。"
        case .connecting: "保持此页面打开；若状态持续，请返回首页后重新进入在线房间。"
        case .roomNotFound: "核对房间码中的字母和数字，并请房主确认房间仍然开放。"
        case .offline: "在系统设置中恢复 Wi-Fi 或蜂窝网络，再回到此页面创建房间。"
        case .versionMismatch: "双方升级到相同应用版本，并确认规则版本均为 v2018.11。"
        }
    }
}
#endif
