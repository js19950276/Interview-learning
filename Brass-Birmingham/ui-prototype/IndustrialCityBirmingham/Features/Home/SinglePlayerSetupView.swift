import SwiftUI

/// 单人挑战会话工厂:1 名玩家(本机宿主)+ 3 个 AI 座位,AIPlayerDriver 即刻接管。
@MainActor
enum SinglePlayerSessionFactory {
    struct Session: Identifiable {
        let id = UUID()
        let store: SessionViewStore
        let driver: AIPlayerDriver
    }

    static func make(
        difficulty: GameCore.AIDifficulty,
        catalog: GameCore.VerifiedGameDataCatalog,
        seed: UInt64 = UInt64.random(in: 1...UInt64.max)
    ) async throws -> Session {
        let roomID = GameCore.RoomID(rawValue: "single-\(UUID().uuidString.prefix(8))")
        let hostID = GameCore.PlayerID(rawValue: "human")
        let hub = LoopbackTransportHub()
        let coordinator = SessionCoordinator(
            configuration: .init(
                protocolVersion: 2,
                rulesetVersion: catalog.catalog.rulesetVersion,
                roomID: roomID,
                playerID: hostID,
                reconnectToken: .init(rawValue: UUID().uuidString),
                hostPlayerID: hostID,
                setupSeed: seed,
                displayName: "你"
            ),
            transport: hub.makeTransport(peerID: hostID),
            rulesMode: .verified(catalog)
        )
        try await coordinator.startSinglePlayerGame(aiDifficulties: Array(repeating: difficulty, count: 3))
        let aiSeats = await coordinator.aiSeatIDs
        let driver = AIPlayerDriver(
            coordinator: coordinator,
            seats: aiSeats.map { AIPlayerDriver.SeatAssignment(seat: $0, difficulty: difficulty) }
        )
        driver.start()
        let store = SessionViewStore(
            coordinator: coordinator,
            role: .host,
            roomID: roomID,
            playerID: hostID,
            hostPlayerID: hostID
        )
        return Session(store: store, driver: driver)
    }
}

/// 单人挑战配置页:选难度,开一局 1 人 + 3 AI。
struct SinglePlayerSetupView: View {
    let onNavigate: (AppRoute) -> Void
    var catalogSource: NearbyCatalogSource = .packagedRules

    @State private var difficulty: GameCore.AIDifficulty = .standard
    @State private var session: SinglePlayerSessionFactory.Session?
    @State private var isStarting = false
    @State private var startError: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    BrassColor.coal.color,
                    BrassColor.iron.color.opacity(0.72),
                    BrassColor.fog.color.opacity(0.5),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: BrassSpacing.xLarge) {
                Text("单人挑战")
                    .font(BrassTypography.display)
                    .foregroundStyle(BrassColor.paper.color)
                    .accessibilityIdentifier("single.title")

                VStack(spacing: BrassSpacing.medium) {
                    Picker("AI 难度", selection: $difficulty) {
                        ForEach(GameCore.AIDifficulty.allCases, id: \.rawValue) { level in
                            Text("AI · \(level.displayName)").tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("single.difficulty")

                    Text("1 名玩家对抗 3 个 AI,全程离线。")
                        .font(BrassTypography.body)
                        .foregroundStyle(BrassColor.fog.color)

                    Button {
                        startSession()
                    } label: {
                        if isStarting {
                            ProgressView().tint(BrassColor.paper.color)
                        } else {
                            Text("开局").foregroundStyle(BrassColor.paper.color)
                        }
                    }
                    .buttonStyle(BrassPrimaryButtonStyle())
                    .disabled(isStarting)
                    .accessibilityIdentifier("single.start")

                    if let startError {
                        Text(startError)
                            .font(BrassTypography.body)
                            .foregroundStyle(.red)
                    }
                }
                .brassPanel()
                .padding(BrassSpacing.large)
            }
            .padding(BrassSpacing.xLarge)
        }
        .navigationTitle("单人挑战")
        .fullScreenCover(item: $session) { session in
            SinglePlayerSessionContainer(session: session)
        }
    }

    private func startSession() {
        guard !isStarting else { return }
        isStarting = true
        startError = nil
        let selected = difficulty
        let source = catalogSource
        Task {
            do {
                let catalog = try source.load()
                session = try await SinglePlayerSessionFactory.make(difficulty: selected, catalog: catalog)
            } catch {
                startError = "开局失败:\(error.localizedDescription)"
            }
            isStarting = false
        }
    }
}

/// 对局容器:快照就绪即进真实对局视图;退出时停驱动器。
private struct SinglePlayerSessionContainer: View {
    @Environment(\.dismiss) private var dismiss
    let session: SinglePlayerSessionFactory.Session

    var body: some View {
        ZStack(alignment: .topLeading) {
            if session.store.snapshot != nil {
                RealMatchView(store: session.store)
            } else {
                ProgressView("正在开局…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button {
                session.driver.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(BrassColor.paper.color)
                    .frame(width: 40, height: 40)
                    .background(BrassColor.coal.color.opacity(0.84), in: Circle())
            }
            .padding(BrassSpacing.medium)
            .accessibilityLabel("退出单人挑战")
        }
        .onDisappear { session.driver.stop() }
    }
}
