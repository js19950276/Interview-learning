import Foundation
import Combine
import PokerEngine

// MARK: - 房主 VM

@MainActor
final class HostGameViewModel: ObservableObject, GamePresenting {
    @Published private(set) var lobby: LobbyState?
    @Published private(set) var gameState: GameState?
    /// 启动/开局失败的用户可读问题（NearbyIssue 映射）。
    @Published var issue: String?
    @Published private(set) var roomID: String?

    private let session: HostSession
    private var updatesTask: Task<Void, Never>?
    private var previousResult: HandResult?

    init(configuration: HostConfiguration, transport: (any Transport)? = nil) {
        session = transport.map { HostSession(configuration: configuration, transport: $0) }
            ?? HostSession(configuration: configuration)
    }

    /// 任何界面的「退出」只把 VM 置 nil；会话断开统一在这里兜底，避免大厅/对局两处双重清理。
    deinit {
        let session = session
        Task { await session.disconnect() }
    }

    var mySeat: Int { 0 }
    var canStartGame: Bool {
        guard let lobby else { return false }
        return lobby.players.count >= 2 && lobby.players.allSatisfy(\.ready)
    }

    func start() async {
        beginConsumingUpdates()
        do {
            try await session.startHosting()
            roomID = await session.roomIDValue()
        } catch {
            let mapped = NearbyPreflight.issue(for: error)
            issue = mapped.title + "：" + mapped.recoveryMessage
        }
    }

    func setReady(_ value: Bool) async { await session.setReady(value) }
    func updateTable(_ config: GameConfig) async { await session.updateTableConfig(config) }

    func startGame() async {
        do {
            try await session.startGame()
            // HostSession.startGame 只向客机扇出首帧快照、不向 updates 泵发 .state（首个 .state
            // 在第一次引擎变更才出现）；房主侧首手状态经观测口直读，后续变更走泵。
            gameState = await session.gameState()
        }
        catch {
            switch error {
            case HostSession.HostError.notEnoughPlayers: issue = "至少需要 2 名玩家才能开局"
            case HostSession.HostError.notAllReady: issue = "还有玩家没有准备"
            default: issue = "开局失败：\(error.localizedDescription)"
            }
        }
    }

    func act(_ action: PlayerAction) async { await session.act(action) }
    func nextHand() async { await session.requestNextHand() }

    func leave() async {
        updatesTask?.cancel()
        updatesTask = nil
        await session.disconnect()
    }

    func applicationDidBecomeActive() async { await session.applicationDidBecomeActive() }

    // MARK: - 会话更新泵（@MainActor Task 内 for-await）

    func beginConsumingUpdates() {
        guard updatesTask == nil else { return }
        // 泵闭包捕获 let-local 会话而非隐式强 self：否则 for-await 挂起期间 VM 永不 deinit（退出即断开落空）
        let session = session
        updatesTask = Task { [weak self] in
            let updates = session.updates
            for await update in updates {
                guard let self else { break }
                self.consume(update)
            }
        }
    }

    private func consume(_ update: HostUpdate) {
        switch update {
        case let .lobby(value):
            lobby = value
        case let .state(value):
            // handOver→新街道的边界捕获上一手结果（对局头「上一手：X 赢 Y」）
            if gameState?.street == .handOver, value.street != .handOver {
                previousResult = gameState?.handResult
            }
            gameState = value
        }
    }

    // MARK: - GamePresenting

    var surface: (any TableSurface)? { gameState }
    var humanLegal: LegalActions? {
        guard let s = gameState, s.actorSeat == 0,
              [.preflop, .flop, .turn, .river].contains(s.street) else { return nil }
        return legalActions(s)
    }
    var lastResult: HandResult? { previousResult ?? gameState?.handResult }
    var isHandOver: Bool { gameState?.street == .handOver }
    var isSessionOver: Bool { gameState?.tournamentOver == true }
}

// MARK: - 客机 VM

@MainActor
final class GuestGameViewModel: ObservableObject, GamePresenting {
    @Published private(set) var lobby: LobbyState?
    @Published private(set) var snapshot: TableSnapshot?
    @Published private(set) var reconnecting = false
    @Published private(set) var mySeat: Int?
    /// 行动被拒等瞬态提示；加入失败等致命问题在 fatal。
    @Published var warning: String?
    @Published var fatal: String?

    private let session: GuestSession
    private var updatesTask: Task<Void, Never>?
    private var previousResult: HandResult?

    init(roomID: String, displayName: String,
         deviceID: String = LocalIdentity.deviceID, transport: (any Transport)? = nil) {
        session = transport.map { GuestSession(roomID: roomID, deviceID: deviceID,
                                               displayName: displayName, transport: $0) }
            ?? GuestSession(roomID: roomID, deviceID: deviceID, displayName: displayName)
        beginConsumingUpdates()
    }

    deinit {
        let session = session
        Task { await session.leave() }
    }

    func join() async {
        do { try await session.join() }
        catch {
            if case let GuestSession.GuestError.rejected(reason) = error {
                fatal = rejectionText(reason)
            } else {
                // 传输生命周期错误（本地网络权限被拒/Wi-Fi 关闭等）优先映射 NearbyIssue 文案；
                // 真正的连接失败才落到超时提示。
                let mapped = NearbyPreflight.issue(for: error)
                if mapped != .connectionFailed {
                    fatal = mapped.title + "：" + mapped.recoveryMessage
                } else {
                    fatal = "加入房间超时，请确认房主页面仍开着后重试"
                }
            }
        }
    }

    func setReady(_ value: Bool) async { await session.setReady(value) }
    func act(_ action: PlayerAction) async { await session.act(action) }
    func nextHand() async { await session.requestNextHand() }

    func leave() async {
        updatesTask?.cancel()
        updatesTask = nil
        await session.leave()
    }

    func applicationDidBecomeActive() async { await session.applicationDidBecomeActive() }

    var inGame: Bool { snapshot != nil }

    private func beginConsumingUpdates() {
        // 同房主泵：捕获 let-local 会话，保证 VM 可 deinit → 退出即 leave（发 bye）
        let session = session
        updatesTask = Task { [weak self] in
            let updates = session.updates
            for await update in updates {
                guard let self else { break }
                self.consume(update)
            }
        }
    }

    private func consume(_ update: GuestUpdate) {
        switch update {
        case let .joined(seat):
            mySeat = seat
            reconnecting = false
        case let .lobby(value):
            lobby = value
        case let .snapshot(value):
            if snapshot?.street == .handOver, value.street != .handOver {
                previousResult = snapshot?.handResult
            }
            snapshot = value
            reconnecting = false
            warning = nil
        case .disconnected:
            reconnecting = true
        case let .rejected(reason):
            if fatal == nil { warning = rejectionText(reason) }
        }
    }

    private func rejectionText(_ reason: RejectionReason) -> String {
        switch reason {
        case .roomFull: "房间已满（9 座）"
        case .gameStarted: "对局已开始，不接受新玩家"
        case .versionMismatch: "版本不一致，请和房主升级到相同版本"
        case .illegalAction: "动作不合法，已刷新牌面"
        case .notYourTurn: "还没轮到你"
        }
    }

    // MARK: - GamePresenting

    var surface: (any TableSurface)? { snapshot }
    var humanLegal: LegalActions? { snapshot?.yourLegal }
    var lastResult: HandResult? { previousResult ?? snapshot?.handResult }
    var isHandOver: Bool { snapshot?.street == .handOver }
    var isSessionOver: Bool { snapshot?.tournamentOver == true }
}

// MARK: - 搜房模型

@MainActor
final class RoomBrowserModel: ObservableObject {
    @Published private(set) var rooms: [RoomListing] = []
    @Published private(set) var searching = false
    @Published var issue: String?

    private let browser: BonjourRoomBrowser
    private var task: Task<Void, Never>?

    init() { browser = BonjourRoomBrowser() }

    func start() {
        guard task == nil else { return }
        searching = true
        issue = nil
        // 同 VM 泵：捕获 let-local 浏览器，不隐式强捕 self（模型可释放）
        let browser = browser
        task = Task { [weak self] in
            let states = browser.states
            for await state in states {
                guard let self else { break }
                switch state {
                case .searching: self.searching = true
                case .found(let rooms): self.rooms = rooms; self.searching = false
                case .empty: self.rooms = []; self.searching = false
                case .failed(let issue): self.issue = issue.title; self.searching = false
                }
            }
        }
        Task { await browser.start() }
    }

    func stop() {
        task?.cancel()
        task = nil
        // 同上：捕获 let-local 浏览器，避免隐式强捕 self（模型可释放）
        let browser = browser
        Task { await browser.cancel() }
    }
}
