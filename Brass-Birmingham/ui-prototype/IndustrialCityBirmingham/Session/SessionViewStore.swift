import Foundation
import Observation
import OSLog
import SwiftUI

nonisolated enum SessionRole: String, Equatable, Sendable { case host, guest }

nonisolated struct LegalResponseGate: Equatable, Sendable {
    private(set) var requestID: String?
    private(set) var baseVersion: GameCore.AuthoritativeVersion?
    private(set) var draftDigest: String?

    mutating func begin(
        requestID: String,
        baseVersion: GameCore.AuthoritativeVersion,
        draftDigest: String = ""
    ) {
        self.requestID = requestID
        self.baseVersion = baseVersion
        self.draftDigest = draftDigest
    }

    mutating func clear() {
        requestID = nil
        baseVersion = nil
        draftDigest = nil
    }

    func accepts(
        _ response: GameCore.LegalActionResponse,
        currentVersion: GameCore.AuthoritativeVersion
    ) -> Bool {
        response.requestID == requestID
            && response.baseVersion == baseVersion
            && response.draftDigest == draftDigest
            && response.baseVersion == currentVersion
    }
}

@MainActor
@Observable
final class NearbyPersistenceState {
    let persistenceFactory: SessionPersistenceFactory

    init(persistenceFactory: SessionPersistenceFactory = .nearbyRuntime) {
        self.persistenceFactory = persistenceFactory
    }
}

@MainActor
enum NearbyHostRecoveryRoute {
    static func makeStore(
        reference: RecoverableSessionReference,
        identity: NearbySessionIdentity,
        persistenceFactory: SessionPersistenceFactory,
        transport: some Transport,
        catalog: GameCore.VerifiedGameDataCatalog
    ) async throws -> SessionViewStore {
        guard reference.role == .host else { throw SessionCoordinator.Error.hostOnly }
        if catalog.catalog.rulesetVersion != reference.rulesetVersion {
            throw SnapshotStoreError.rulesetMismatch
        }
        let coordinator = try await persistenceFactory.makeCoordinator(
            configuration: .init(
                protocolVersion: reference.protocolVersion,
                rulesetVersion: reference.rulesetVersion,
                roomID: reference.roomID,
                playerID: reference.playerID,
                reconnectToken: identity.reconnectToken,
                hostPlayerID: reference.playerID
            ),
            role: .host,
            transport: transport,
            rulesMode: .verified(catalog)
        )
        return SessionViewStore(
            coordinator: coordinator,
            role: .host,
            roomID: reference.roomID,
            playerID: reference.playerID,
            hostPlayerID: reference.playerID
        )
    }
}

@MainActor
@Observable
final class SessionViewStore {
    enum SyncStatus: String, Equatable, Sendable {
        case connecting
        case synchronized
        case recovering
        case failed
    }

    private let coordinator: SessionCoordinator
    let presentationCatalog: GameCore.VerifiedGameDataCatalog?
    private let role: SessionRole
    private nonisolated let observationTask = SessionObservationTask()
    private var pendingSubmissionVersion: GameCore.AuthoritativeVersion?
    private var legalResponseGate = LegalResponseGate()
#if DEBUG
    private var harnessPort: UInt16?
    private var fixtureGuest: SessionCoordinator?
    private var recoveryUIFixtureStatusOverride: SyncStatus?
    private var localUIFixturePresentationEraOverride: GameCore.Era?
#endif
    private var didConnect = false
    private var didDisconnect = false

    private(set) var roomID: GameCore.RoomID
    private(set) var localPlayerID: GameCore.PlayerID
    private(set) var playerNames: [GameCore.PlayerID: String] = [:]
    private(set) var playerColors: [GameCore.PlayerID: GameCore.PlayerColor] = [:]
    private(set) var actionLog: [MatchActionLogEntry] = []
    private(set) var hostPlayerID: GameCore.PlayerID
    private(set) var players: [GameCore.PlayerID] = []
    private(set) var readyPlayerIDs: [GameCore.PlayerID] = []
    private(set) var snapshot: GameCore.ViewSnapshot?
    private(set) var syncStatus: SyncStatus = .connecting
    private(set) var errorMessage: String?
    private(set) var selectedCardID: String?
    private(set) var legalResponse: GameCore.LegalActionResponse?

    var hand: [String] {
        snapshot?.players.first(where: { $0.id == localPlayerID })?.hand ?? []
    }

    var version: GameCore.AuthoritativeVersion {
        snapshot?.authoritativeVersion ?? .init(rawValue: 0)
    }

    var isHost: Bool { role == .host }
    var isReady: Bool { readyPlayerIDs.contains(localPlayerID) }
    /// 对局模式:主机可改(仅大厅阶段),客机只读、跟随大厅广播。
    var matchModeSelection: GameCore.MatchMode = .standard

    func setMatchMode(_ mode: GameCore.MatchMode) async {
        do { try await coordinator.setMatchMode(mode) }
        catch { errorMessage = Self.message(for: error) }
    }

#if DEBUG
    var showsRecoveryUIFixtureControl: Bool { recoveryUIFixtureStatusOverride != nil }
#endif
    var canStart: Bool { isHost && players.count >= 2 && Set(players) == Set(readyPlayerIDs) && snapshot == nil }
    var canSubmitPass: Bool {
        guard let selectedCardID else { return false }
#if DEBUG
        let hasVerifiedPass = snapshot?.match == nil || snapshot?.match?.trivialOptions.contains(where: {
            $0.action == .pass && $0.cardIDs == [selectedCardID]
        }) == true
#else
        let hasVerifiedPass = snapshot?.match?.trivialOptions.contains(where: {
            $0.action == .pass && $0.cardIDs == [selectedCardID]
        }) == true
#endif
        return didConnect
            && syncStatus == .synchronized
            && snapshot?.activePlayerID == localPlayerID
            && hand.contains(selectedCardID)
            && hasVerifiedPass
            && pendingSubmissionVersion == nil
    }

    var availableActions: [GameCore.ActionKind] {
        guard canInteract else { return [] }
        guard let selectedCardID else { return [] }
        return snapshot?.match?.availableActionsByCardID?[selectedCardID] ?? []
    }

    var canInteract: Bool {
        didConnect && syncStatus == .synchronized
            && snapshot?.activePlayerID == localPlayerID
            && pendingSubmissionVersion == nil
            && snapshot?.match != nil
    }

    /// 本回合已落地操作 > 0 且轮到自己时,可整回合撤回。
    var canRetractTurnActions: Bool {
        didConnect && syncStatus == .synchronized
            && snapshot?.activePlayerID == localPlayerID
            && pendingSubmissionVersion == nil
            && (snapshot?.match?.turnActionsTaken ?? 0) > 0
    }

    /// 回合结束待确认:自己两个行动落地后,需点击确认才过轮。
    var canConfirmTurnEnd: Bool {
        didConnect
            && syncStatus == .synchronized
            && snapshot?.awaitingTurnEndConfirmation == true
            && snapshot?.activePlayerID == localPlayerID
            && pendingSubmissionVersion == nil
    }

    var isAwaitingTurnEndConfirmation: Bool {
        snapshot?.awaitingTurnEndConfirmation == true
    }

    /// 确认结束本回合:补牌/回合末结算/强卖都由房主在此时执行。
    func confirmTurnEnd() {
        guard canConfirmTurnEnd else { return }
        Task {
            do { try await coordinator.submit(.confirmTurnEnd) }
            catch { errorMessage = Self.message(for: error) }
        }
    }

    /// 撤回当前回合已执行的全部操作,状态回到回合开始。
    func retractTurnActions() {
        guard canRetractTurnActions else { return }
        Task {
            do { try await coordinator.submit(.retractTurnActions) }
            catch { errorMessage = Self.message(for: error) }
        }
    }

    init(
        coordinator: SessionCoordinator,
        role: SessionRole,
        roomID: GameCore.RoomID = .init(rawValue: ""),
        playerID: GameCore.PlayerID? = nil,
        hostPlayerID: GameCore.PlayerID = .init(rawValue: "host")
    ) {
        self.coordinator = coordinator
        presentationCatalog = coordinator.presentationCatalog
        self.role = role
        self.roomID = roomID
        self.localPlayerID = playerID ?? .init(rawValue: role.rawValue)
        self.hostPlayerID = hostPlayerID
        observationTask.value = Task { [weak self, coordinator] in
            let updates = await coordinator.stateUpdates()
            for await state in updates {
                guard !Task.isCancelled else { return }
                self?.consume(state)
            }
        }
    }

    deinit { observationTask.value?.cancel() }

#if DEBUG
    convenience init(
        coordinator: SessionCoordinator,
        role: SessionRole,
        roomID: GameCore.RoomID,
        playerID: GameCore.PlayerID,
        hostPlayerID: GameCore.PlayerID = .init(rawValue: "host"),
        harnessPort: UInt16?,
        fixtureGuest: SessionCoordinator?,
        localUIFixturePresentationEraOverride: GameCore.Era? = nil
    ) {
        self.init(
            coordinator: coordinator, role: role, roomID: roomID,
            playerID: playerID, hostPlayerID: hostPlayerID
        )
        self.harnessPort = harnessPort
        self.fixtureGuest = fixtureGuest
        self.localUIFixturePresentationEraOverride = localUIFixturePresentationEraOverride
    }

    static func localUIFixture(
        presentationEraOverride: GameCore.Era? = nil
    ) -> SessionViewStore {
        let room = GameCore.RoomID(rawValue: "LOCALUI")
        let host = GameCore.PlayerID(rawValue: "host")
        let guest = GameCore.PlayerID(rawValue: "guest")
        let catalog = try! GameCore.GameDataLoader.loadBundledFixtureCatalog()
        let hub = LoopbackTransportHub()
        let hostCoordinator = SessionCoordinator(configuration: .init(
            protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion, roomID: room, playerID: host,
            reconnectToken: .init(rawValue: "local-ui-host"), hostPlayerID: host, setupSeed: 2
        ), transport: hub.makeTransport(peerID: host), rulesMode: .verified(catalog))
        let guestCoordinator = SessionCoordinator(configuration: .init(
            protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion, roomID: room, playerID: guest,
            reconnectToken: .init(rawValue: "local-ui-guest"), hostPlayerID: host
        ), transport: hub.makeTransport(peerID: guest), rulesMode: .verified(catalog))
        return SessionViewStore(
            coordinator: hostCoordinator, role: .host, roomID: room, playerID: host,
            harnessPort: nil, fixtureGuest: guestCoordinator,
            localUIFixturePresentationEraOverride: presentationEraOverride
        )
    }

    static func localRecoveryUIFixture() -> SessionViewStore {
        let store = localUIFixture()
        store.applyRecoveryUIFixtureStatus(.connecting)
        return store
    }
#endif

    static func nearbyHost(
        roomID: GameCore.RoomID,
        identity: NearbySessionIdentity,
        persistenceFactory: SessionPersistenceFactory = .nearbyRuntime
    ) async throws -> SessionViewStore {
        try await makeNearbyHost(
            roomID: roomID, identity: identity, persistenceFactory: persistenceFactory,
            catalog: GameCore.GameDataLoader.loadBundledSetupCatalog()
        )
    }

    static func nearbyHost(
        roomID: GameCore.RoomID,
        identity: NearbySessionIdentity,
        persistenceFactory: SessionPersistenceFactory = .nearbyRuntime,
        catalog: GameCore.VerifiedGameDataCatalog
    ) async throws -> SessionViewStore {
        try await makeNearbyHost(
            roomID: roomID, identity: identity, persistenceFactory: persistenceFactory, catalog: catalog
        )
    }

    private static func makeNearbyHost(
        roomID: GameCore.RoomID,
        identity: NearbySessionIdentity,
        persistenceFactory: SessionPersistenceFactory,
        catalog: GameCore.VerifiedGameDataCatalog
    ) async throws -> SessionViewStore {
        let hostID = GameCore.PlayerID(rawValue: "host")
        // 混玩统一:模拟器与真机同走 NearbyTransport(Bonjour TCP + 点对点)。
        let transport = NearbyTransport()
        let coordinator = try await persistenceFactory.makeCoordinator(
            configuration: .init(
                protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion, roomID: roomID,
                playerID: hostID, reconnectToken: identity.reconnectToken, hostPlayerID: hostID,
                // 每个新房随机种子:贸易商布局、发牌与顺位洗牌逐局不同。
                setupSeed: UInt64.random(in: 1...UInt64.max),
                displayName: UserDefaults.standard.string(forKey: "playerDisplayName")
            ),
            role: .host,
            transport: transport,
            rulesMode: .verified(catalog)
        )
        return SessionViewStore(
            coordinator: coordinator,
            role: .host, roomID: roomID, playerID: hostID, hostPlayerID: hostID
        )
    }

    static func nearbyGuest(
        room: NearbyRoom,
        identity: NearbySessionIdentity,
        persistenceFactory: SessionPersistenceFactory = .nearbyRuntime
    ) async throws -> SessionViewStore {
        try await makeNearbyGuest(
            room: room, identity: identity, persistenceFactory: persistenceFactory,
            catalog: GameCore.GameDataLoader.loadBundledSetupCatalog()
        )
    }

    static func nearbyGuest(
        room: NearbyRoom,
        identity: NearbySessionIdentity,
        persistenceFactory: SessionPersistenceFactory = .nearbyRuntime,
        catalog: GameCore.VerifiedGameDataCatalog
    ) async throws -> SessionViewStore {
        try await makeNearbyGuest(
            room: room, identity: identity, persistenceFactory: persistenceFactory, catalog: catalog
        )
    }

    private static func makeNearbyGuest(
        room: NearbyRoom,
        identity: NearbySessionIdentity,
        persistenceFactory: SessionPersistenceFactory,
        catalog: GameCore.VerifiedGameDataCatalog
    ) async throws -> SessionViewStore {
        let roomID = GameCore.RoomID(rawValue: room.serviceName)
        let hostID = GameCore.PlayerID(rawValue: "host")
        // 混玩统一:模拟器与真机同走 NearbyTransport(Bonjour TCP + 点对点)。
        let transport = NearbyTransport(serviceName: room.serviceName)
        // 短局客机档案按协议 3 保存:先 2 后 3 探测,成功者即本座位的会话协议,
        // 避免绑着协议 2 空座位撞上短局的提交序号。
        let protocolVersion = await persistenceFactory.guestArchiveProtocol(
            roomID: roomID, playerID: identity.playerID, rulesetVersion: catalog.catalog.rulesetVersion
        ) ?? 2
        let coordinator = try await persistenceFactory.makeCoordinator(
            configuration: .init(
                protocolVersion: protocolVersion, rulesetVersion: catalog.catalog.rulesetVersion, roomID: roomID,
                playerID: identity.playerID, reconnectToken: identity.reconnectToken, hostPlayerID: hostID,
                displayName: UserDefaults.standard.string(forKey: "playerDisplayName")
            ),
            role: .guest,
            transport: transport,
            rulesMode: .verified(catalog)
        )
        return SessionViewStore(
            coordinator: coordinator,
            role: .guest, roomID: roomID, playerID: identity.playerID, hostPlayerID: hostID
        )
    }

    @discardableResult
    func connect() async -> NearbyPreflightIssue? {
        guard !didDisconnect else {
            syncStatus = .failed
            errorMessage = NearbyPreflightIssue.sessionEnded.recoveryMessage
            return .sessionEnded
        }
        guard !didConnect else { return nil }
        errorMessage = nil
        do {
            switch role {
            case .host:
#if DEBUG
                try await coordinator.createRoom(port: harnessPort)
                if let fixtureGuest {
                    try await fixtureGuest.joinRoom()
                    try await coordinator.setReady(true)
                    try await fixtureGuest.setReady(true)
                    _ = try await waitUntil { $0.readyPlayerIDs.count == 2 }
                    try await coordinator.startGame()
                }
#else
                try await coordinator.createRoom()
#endif
            case .guest: try await coordinator.joinRoom()
            }
            didConnect = true
#if DEBUG
            if let recoveryUIFixtureStatusOverride {
                applyRecoveryUIFixtureStatus(recoveryUIFixtureStatusOverride)
            } else if syncStatus != .recovering, snapshot != nil || !players.isEmpty {
                syncStatus = .synchronized
            }
#else
            if syncStatus != .recovering, snapshot != nil || !players.isEmpty {
                syncStatus = .synchronized
            }
#endif
            return nil
        } catch {
            Logger(
                subsystem: "com.didi.prototype.IndustrialCityBirmingham",
                category: "NearbySession"
            ).error("Session connect failed: \(String(reflecting: error), privacy: .public)")
            let issue = NearbyPreflight.issue(for: error)
            syncStatus = .failed
            errorMessage = issue.recoveryMessage
            return issue
        }
    }

#if DEBUG
    /// 脚本 harness:连接→准备→(房主)开局,然后由 ScriptHarnessBot 自动打完整局。
    /// 全程向 stdout 打 `INDUSTRIALCITY_LOCAL` 标记,供双模拟器脚本跟踪进度、判定终局。
    func runScriptHarness() async {
        await connect()
        guard syncStatus != .failed else { return }
        await setReady(true)
        let seed = ScriptHarnessBot.seed(from: ProcessInfo.processInfo.arguments)
            ?? ScriptHarnessBot.defaultSeed(roomID: roomID.rawValue)
        var bot = ScriptHarnessBot(seed: seed)
        print("INDUSTRIALCITY_LOCAL harness-loop seed=\(seed)")
        do {
            if isHost {
                _ = try await waitUntil { $0.readyPlayerIDs.count >= 2 }
                try await coordinator.startGame()
            }
            try await playScriptedMatch(bot: &bot)
        } catch {
            errorMessage = Self.message(for: error)
            print("INDUSTRIALCITY_LOCAL failed error=\(error)")
        }
    }

    private enum HarnessLegalOutcome {
        case response(GameCore.LegalActionResponse)
        case deadEnd
    }

    private static func scriptHarnessDeadline() -> Date {
        let arguments = ProcessInfo.processInfo.arguments
        let seconds: Double = if let index = arguments.firstIndex(of: "-local-harness-deadline"),
            arguments.indices.contains(index + 1),
            let value = Double(arguments[index + 1]) {
            value
        } else {
            720
        }
        return Date().addingTimeInterval(max(60, seconds))
    }

    /// 主循环:按快照状态推进——终局→结算确认→强制出售→轮到自己出动作,直到 gameEnded。
    private func playScriptedMatch(bot: inout ScriptHarnessBot) async throws {
        let deadline = Self.scriptHarnessDeadline()
        while Date() < deadline {
            if syncStatus == .failed {
                throw SessionCoordinator.Error.harnessPhaseTimedOut
            }
            if let ended = snapshot?.gameEnded {
                reportScriptedGameOver(ended)
                return
            }
            if let intermission = snapshot?.eraIntermission {
                if intermission.confirmedPlayerIDs.contains(localPlayerID) == false {
                    confirmEraTransition()
                    print("INDUSTRIALCITY_LOCAL era-confirmed actor=\(localPlayerID.rawValue) era=\(intermission.settledEra)")
                }
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            if snapshot?.forcedSale != nil {
                if snapshot?.match?.forcedSaleDebtorID == localPlayerID {
                    await resolveScriptedForcedSale(bot: &bot, deadline: deadline)
                }
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            if snapshot?.awaitingTurnEndConfirmation == true {
                if snapshot?.activePlayerID == localPlayerID {
                    errorMessage = nil
                    do { try await coordinator.submit(.confirmTurnEnd) }
                    catch { errorMessage = Self.message(for: error) }
                    print("INDUSTRIALCITY_LOCAL turn-end-confirmed actor=\(localPlayerID.rawValue) version=\(version.rawValue)")
                }
                try? await Task.sleep(for: .milliseconds(60))
                continue
            }
            if snapshot?.activePlayerID == localPlayerID, canInteract {
                await takeScriptedAction(bot: &bot, deadline: deadline)
                continue
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        throw SessionCoordinator.Error.harnessPhaseTimedOut
    }

    /// 轮到自己时挑一个合法动作:多次尝试(卡,动作)组合走多步合法流,
    /// 全部走不通时兜底 pass(恒合法),保证对局必然推进。
    private func takeScriptedAction(bot: inout ScriptHarnessBot, deadline: Date) async {
        for _ in 0..<6 {
            guard canInteract, let byCardID = snapshot?.match?.availableActionsByCardID,
                  let pick = bot.pickAction(byCardID: byCardID) else { break }
            if await walkScriptedDraft(cardID: pick.cardID, action: pick.action, bot: &bot, deadline: deadline) {
                return
            }
        }
        await scriptPass(bot: &bot, deadline: deadline)
    }

    /// 多步合法动作流:请求→按响应补选择→拿到 completePayload 后提交。
    /// 走不通(被拒/过期/死路)返回 false,由调用方换组合重试。
    private func walkScriptedDraft(
        cardID: String,
        action: GameCore.ActionKind,
        bot: inout ScriptHarnessBot,
        deadline: Date
    ) async -> Bool {
        selectCard(cardID)
        var selections: [GameCore.LegalChoiceValue] = []
        for _ in 0..<24 {
            guard canInteract else { return false }
            let draft = GameCore.LegalActionDraft(action: action, cardID: cardID, selections: selections)
            guard let digest = try? draft.canonicalDigest() else { return false }
            let baseVersion = version
            errorMessage = nil
            await requestLegalOptions(action: action, selections: selections)
            guard let outcome = await waitForScriptedLegalResponse(
                digest: digest, baseVersion: baseVersion,
                deadline: min(deadline, Date().addingTimeInterval(15))
            ), case .response(let response) = outcome else {
                return false
            }
            if response.completePayload != nil {
                await submitCompleteLegalResponse()
                await waitScriptedSubmissionSettled(deadline: deadline)
                let landed = pendingSubmissionVersion == nil && errorMessage == nil
                if landed {
                    print("INDUSTRIALCITY_LOCAL bot-action actor=\(localPlayerID.rawValue) action=\(action.rawValue) card=\(cardID) version=\(version.rawValue) turn=\(snapshot?.turn ?? -1)")
                }
                return landed
            }
            guard let choice = bot.pickChoice(response.nextChoices) else { return false }
            selections.append(choice.value)
        }
        return false
    }

    /// pass 兜底:trivialOptions 里带现成 payload,提交即推进。
    private func scriptPass(bot: inout ScriptHarnessBot, deadline: Date) async {
        guard canInteract, let cardID = bot.pickPassCard(snapshot?.match?.trivialOptions ?? []) else { return }
        selectCard(cardID)
        await submitPass()
        await waitScriptedSubmissionSettled(deadline: deadline)
        if pendingSubmissionVersion == nil, errorMessage == nil {
            print("INDUSTRIALCITY_LOCAL bot-action actor=\(localPlayerID.rawValue) action=pass card=\(cardID) version=\(version.rawValue) turn=\(snapshot?.turn ?? -1)")
        }
    }

    /// 强制出售:与普通多步流同构,selections 为 industryPlacement 累积列表。
    private func resolveScriptedForcedSale(bot: inout ScriptHarnessBot, deadline: Date) async {
        var placementIDs: [String] = []
        for _ in 0..<24 {
            let draft = GameCore.LegalActionDraft(
                action: .forcedSale, cardID: nil,
                selections: placementIDs.map { .industryPlacement(id: $0) }
            )
            guard let digest = try? draft.canonicalDigest() else { return }
            let baseVersion = version
            errorMessage = nil
            await requestForcedSaleOptions(placementIDs: placementIDs)
            guard let outcome = await waitForScriptedLegalResponse(
                digest: digest, baseVersion: baseVersion,
                deadline: min(deadline, Date().addingTimeInterval(15))
            ), case .response(let response) = outcome else {
                return
            }
            if response.completePayload != nil {
                await submitForcedSale()
                await waitScriptedSubmissionSettled(deadline: deadline)
                print("INDUSTRIALCITY_LOCAL forced-sale actor=\(localPlayerID.rawValue) count=\(placementIDs.count) version=\(version.rawValue)")
                return
            }
            guard let choice = bot.pickChoice(response.nextChoices),
                  case .industryPlacement(let id) = choice.value else { return }
            placementIDs.append(id)
        }
    }

    /// 等待合法流响应落到 legalResponse;deadEnd = 查询被拒/版本前移/串扰响应。
    private func waitForScriptedLegalResponse(
        digest: String,
        baseVersion: GameCore.AuthoritativeVersion,
        deadline: Date
    ) async -> HarnessLegalOutcome? {
        while Date() < deadline {
            if let response = legalResponse {
                return response.draftDigest == digest ? .response(response) : .deadEnd
            }
            if version != baseVersion { return .deadEnd }
            if errorMessage != nil { return .deadEnd }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return nil
    }

    /// 等待已提交动作落地(版本前移)或被拒;两者都会清 pendingSubmissionVersion。
    private func waitScriptedSubmissionSettled(deadline: Date) async {
        while Date() < deadline, pendingSubmissionVersion != nil {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private func reportScriptedGameOver(_ ended: GameCore.GameTransitionEvent.GameEndedDetails) {
        let standings = ended.standings
            .map { $0.map(\.rawValue).sorted().joined(separator: "+") }
            .joined(separator: "|")
        print("INDUSTRIALCITY_LOCAL game-over standings=\(standings)")
        if let match = snapshot?.match {
            for player in match.players {
                print("INDUSTRIALCITY_LOCAL final player=\(player.id.rawValue) vp=\(player.victoryPoints) income=\(player.incomeLevel) cash=\(player.cash) spent=\(player.spent)")
            }
        }
        print("INDUSTRIALCITY_LOCAL harness-complete")
    }
#endif

#if DEBUG
    func advanceRecoveryUIFixture() {
        switch recoveryUIFixtureStatusOverride {
        case .connecting:
            applyRecoveryUIFixtureStatus(.recovering)
        case .recovering:
            recoveryUIFixtureStatusOverride = nil
            syncStatus = .synchronized
            errorMessage = nil
        default:
            break
        }
    }
#endif

    func setReady(_ value: Bool) async {
        do { try await coordinator.setReady(value) }
        catch { errorMessage = Self.message(for: error) }
    }

    /// 显示名:优先玩家自命名,缺省回退原始 ID。
    func displayName(for playerID: GameCore.PlayerID) -> String {
        if let name = playerNames[playerID], name.isEmpty == false { return name }
        if playerID == hostPlayerID { return "房主" }
        return playerID.rawValue
    }

    /// 设置自己的显示名:落盘并在会话内同步(房主重播大厅,客人发 rename)。
    func setDisplayName(_ name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
        guard trimmed.isEmpty == false else { return }
        UserDefaults.standard.set(trimmed, forKey: "playerDisplayName")
        Task { await coordinator.updateDisplayName(trimmed) }
    }

    /// 时代结算确认:提交后由房主等待全员确认再进入铁路时代。
    func confirmEraTransition() {
        Task {
            do { try await coordinator.submit(.confirmEraIntermission) }
            catch { errorMessage = Self.message(for: error) }
        }
    }

    /// 大厅内选择代表色:记忆偏好并提交给房主(被占用时房主拒绝,保持原色)。
    func chooseColor(_ color: GameCore.PlayerColor) {
        guard playerColors[localPlayerID] != color else { return }
        let takenByOther = playerColors.contains { $0.key != localPlayerID && $0.value == color }
        guard takenByOther == false else { return }
        UserDefaults.standard.set(color.rawValue, forKey: "playerColor")
        Task { await coordinator.chooseColor(color) }
    }

    func startGame() async {
        guard isHost else {
            errorMessage = Self.message(for: SessionCoordinator.Error.hostOnly)
            return
        }
        do { try await coordinator.startGame() }
        catch { errorMessage = Self.message(for: error) }
    }

    func selectCard(_ id: String) {
        guard hand.contains(id) else { return }
        cancelLegalFlow()
        selectedCardID = id
        errorMessage = nil
    }

    func submitPass() async {
        guard canSubmitPass, let selectedCardID else { return }
        if let option = snapshot?.match?.trivialOptions.first(where: {
            $0.action == .pass && $0.cardIDs == [selectedCardID]
        }) {
            await sendPayload(option.payload)
            return
        }
#if DEBUG
        if snapshot?.match == nil {
            await sendPayload(.pass(.init(cardID: selectedCardID)))
        }
#endif
    }

    func requestLegalOptions(action: GameCore.ActionKind, selections: [GameCore.LegalChoiceValue] = []) async {
        guard canInteract, let selectedCardID else { return }
        let requestID = UUID().uuidString
        let draft = GameCore.LegalActionDraft(
            action: action, cardID: selectedCardID, selections: selections
        )
        guard let digest = try? draft.canonicalDigest() else { return }
        legalResponseGate.begin(requestID: requestID, baseVersion: version, draftDigest: digest)
        legalResponse = nil
        do {
            try await coordinator.requestLegalOptions(
                requestID: requestID,
                draft: draft
            )
        } catch {
            legalResponseGate.clear()
            errorMessage = Self.message(for: error)
        }
    }

    func requestForcedSaleOptions(placementIDs: [String] = []) async {
        guard didConnect, syncStatus == .synchronized,
              snapshot?.activePlayerID == localPlayerID,
              pendingSubmissionVersion == nil,
              snapshot?.forcedSale != nil else { return }
        let requestID = UUID().uuidString
        let draft = GameCore.LegalActionDraft(
            action: .forcedSale, cardID: nil,
            selections: placementIDs.map { .industryPlacement(id: $0) }
        )
        guard let digest = try? draft.canonicalDigest() else { return }
        legalResponseGate.begin(requestID: requestID, baseVersion: version, draftDigest: digest)
        legalResponse = nil
        do {
            try await coordinator.requestLegalOptions(
                requestID: requestID,
                draft: draft
            )
        } catch {
            cancelLegalFlow()
            errorMessage = Self.message(for: error)
        }
    }

    func submitCompleteLegalResponse() async {
        guard canInteract, let response = legalResponse,
              legalResponseGate.accepts(response, currentVersion: version),
              let payload = response.completePayload else { return }
        await sendPayload(payload)
    }

    func submitBuild(_ intent: GameCore.BuildIntent) async { await sendValidatedComplete(.build(intent)) }
    func submitNetwork(_ intent: GameCore.NetworkIntent) async { await sendValidatedComplete(.network(intent)) }
    func submitDevelop(_ intent: GameCore.DevelopIntent) async { await sendValidatedComplete(.develop(intent)) }
    func submitSell(_ intent: GameCore.SellIntent) async { await sendValidatedComplete(.sell(intent)) }
    func submitLoan(_ intent: GameCore.LoanIntent) async { await sendValidatedComplete(.loan(intent)) }
    func submitScout(_ intent: GameCore.ScoutIntent) async { await sendValidatedComplete(.scout(intent)) }

    func submitForcedSale() async {
        guard case .forcedSale = legalResponse?.completePayload else { return }
        await submitCompleteLegalResponse()
    }

    func cancelLegalFlow() {
        legalResponseGate.clear()
        legalResponse = nil
    }

    func disconnect() async {
        didDisconnect = true
        observationTask.value?.cancel()
        await coordinator.disconnect()
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        guard phase == .background else { return }
        do {
            try await coordinator.persistForBackground()
        } catch {
            syncStatus = .failed
            errorMessage = Self.persistenceFailureMessage
        }
    }

#if DEBUG
    func setRecoveringForTesting(_ value: Bool) {
        syncStatus = value ? .recovering : .synchronized
    }

    func submitPassForTestingIgnoringTurn() async {
        guard let selectedCardID else { return }
        await sendPayload(.pass(.init(cardID: selectedCardID)))
    }

    func submitForTesting(_ payload: GameCore.PlayerIntent.Payload) async throws {
        try await coordinator.submit(payload)
    }
#endif

    private func sendValidatedComplete(_ payload: GameCore.PlayerIntent.Payload) async {
        guard canInteract,
              legalResponse?.completePayload == payload,
              legalResponse.map({ legalResponseGate.accepts($0, currentVersion: version) }) == true
        else { return }
        await sendPayload(payload)
    }

    private func sendPayload(_ payload: GameCore.PlayerIntent.Payload) async {
        pendingSubmissionVersion = version
        errorMessage = nil
        do { try await coordinator.submit(payload) }
        catch {
            pendingSubmissionVersion = nil
            if error as? SessionCoordinator.Error == .persistenceUnavailable {
                syncStatus = .failed
                errorMessage = Self.persistenceFailureMessage
            } else {
                errorMessage = Self.message(for: error)
            }
        }
    }

    private func consume(_ state: SessionCoordinator.State) {
        roomID = state.roomID
        localPlayerID = state.playerID
        hostPlayerID = state.hostPlayerID
        players = state.playerIDs
        playerNames = state.playerNames
        playerColors = state.playerColors
        actionLog = state.actionLog
        readyPlayerIDs = state.readyPlayerIDs
        matchModeSelection = state.matchMode
        let previousVersion = snapshot?.authoritativeVersion
#if DEBUG
        snapshot = localUIFixturePresentationSnapshot(from: state.snapshot)
#else
        snapshot = state.snapshot
#endif

        if state.recoveryError != nil {
            syncStatus = .failed
            errorMessage = Self.recoveryMaterialFailureMessage
        } else if state.persistenceError != nil {
            syncStatus = .failed
            errorMessage = Self.persistenceFailureMessage
        } else if state.pauseReason == .hostDisconnected {
            syncStatus = .recovering
            errorMessage = Self.hostDisconnectedMessage
        } else if state.pauseReason == .stateRecovery {
            syncStatus = .recovering
            errorMessage = nil
        } else if !state.peersNeedingRecovery.isEmpty || state.lastDeliveryError != nil {
            syncStatus = .recovering
        } else if didConnect && (state.snapshot != nil || !state.playerIDs.isEmpty) {
            syncStatus = .synchronized
        }

        if state.recoveryError != nil {
            pendingSubmissionVersion = nil
        } else if state.persistenceError != nil {
            pendingSubmissionVersion = nil
        } else if state.pauseReason == .hostDisconnected || state.pauseReason == .stateRecovery {
            pendingSubmissionVersion = nil
        } else if let rejection = state.lastIntentRejection {
            pendingSubmissionVersion = nil
            cancelLegalFlow()
            errorMessage = Self.message(for: rejection.reasonCode)
        } else if let pendingSubmissionVersion,
                  state.snapshot?.authoritativeVersion.rawValue ?? 0 > pendingSubmissionVersion.rawValue {
            self.pendingSubmissionVersion = nil
            selectedCardID = nil
            cancelLegalFlow()
            errorMessage = nil
        } else if previousVersion != state.snapshot?.authoritativeVersion {
            errorMessage = nil
        } else if errorMessage == Self.persistenceFailureMessage {
            errorMessage = nil
        } else if state.pauseReason == nil, errorMessage == Self.hostDisconnectedMessage {
            errorMessage = nil
        }

        if let response = state.lastLegalResponse,
           legalResponseGate.accepts(response, currentVersion: version) {
            if let error = response.error {
                legalResponse = nil
                errorMessage = Self.message(for: error)
            } else {
                legalResponse = response
            }
        }
        if previousVersion != state.snapshot?.authoritativeVersion {
            cancelLegalFlow()
        }

#if DEBUG
        if let recoveryUIFixtureStatusOverride {
            syncStatus = recoveryUIFixtureStatusOverride
            errorMessage = recoveryUIFixtureStatusOverride == .recovering ? Self.recoveryUIFixtureMessage : nil
        }
#endif
    }

#if DEBUG
    private func localUIFixturePresentationSnapshot(
        from snapshot: GameCore.ViewSnapshot?
    ) -> GameCore.ViewSnapshot? {
        guard let snapshot,
              let localUIFixturePresentationEraOverride,
              var match = snapshot.match else { return snapshot }
        match.era = localUIFixturePresentationEraOverride
        return GameCore.ViewSnapshot(
            roomID: snapshot.roomID,
            recipient: snapshot.recipient,
            players: snapshot.players,
            activePlayerID: snapshot.activePlayerID,
            turn: snapshot.turn,
            actionNumber: snapshot.actionNumber,
            authoritativeVersion: snapshot.authoritativeVersion,
            discardPile: snapshot.discardPile,
            forcedSale: snapshot.forcedSale,
            awaitingTurnEndConfirmation: snapshot.awaitingTurnEndConfirmation,
            match: match,
            checksum: snapshot.checksum
        )
    }

    private func applyRecoveryUIFixtureStatus(_ status: SyncStatus) {
        recoveryUIFixtureStatusOverride = status
        syncStatus = status
        errorMessage = status == .recovering ? Self.recoveryUIFixtureMessage : nil
    }
#endif

    private static let persistenceFailureMessage = "无法安全保存对局，已暂停新行动。请重试恢复。"
    private static let hostDisconnectedMessage = "正在等待原房主恢复连接，期间无法提交新行动。"
    private static let recoveryMaterialFailureMessage = "本机恢复材料连续校验失败，已安全清理。请返回附近房间重新连接。"

    private static func message(for error: any Swift.Error) -> String {
        if let error = error as? GameCore.LegalActionQueryError {
            return switch error {
            case .staleVersion: "对局状态已更新，请重新选择。"
            case .notActivePlayer: "当前不是你的行动回合。"
            case .invalidCard: "所选手牌已不可用，请重新选择。"
            case .invalidPrefix: "该选择组合不合法，请修改后重试。"
            case .malformedQuery: "行动请求格式无效。"
            }
        }
        if let error = error as? SessionCoordinator.Error {
            return switch error {
            case .hostOnly: "仅房主可执行此操作。"
            case .notAllPlayersReady: "仍有玩家未准备。"
            case .gameAlreadyStarted: "对局已经开始。"
            case .dataUnavailable: "已验证的游戏数据不可用。"
            case .sessionPaused: "对局已暂停，等待恢复。"
            default: "操作未完成，请重试。"
            }
        }
        return "操作未完成，请重试。"
    }

    private static func message(for reason: GameCore.RejectedIntent.ReasonCode) -> String {
        switch reason {
        case .notActivePlayer: "当前不是你的行动回合。"
        case .staleAuthoritativeVersion: "对局状态已更新，请重新选择。"
        case .missingDiscardCard: "所选手牌已不可用，请重新选择。"
        case .invalidAction: "该行动不合法，请修改选择。"
        case .persistenceUnavailable: persistenceFailureMessage
        case .internalFailure: "房主规则引擎已暂停，等待恢复。"
        case .wrongRoom, .protocolVersionMismatch, .rulesetVersionMismatch,
             .unknownSender, .invalidReconnectToken:
            "会话身份或版本不匹配，请重新加入房间。"
        }
    }
#if DEBUG
    private static let recoveryUIFixtureMessage = "连接恢复中，已暂停新行动；等待状态同步完成。"
#endif

    private func waitUntil(_ predicate: @escaping @Sendable (SessionCoordinator.State) -> Bool) async throws -> SessionCoordinator.State {
        let coordinator = self.coordinator
        return try await withThrowingTaskGroup(of: SessionCoordinator.State.self) { group in
            group.addTask {
                let updates = await coordinator.stateUpdates()
                for await state in updates where predicate(state) { return state }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw SessionCoordinator.Error.harnessPhaseTimedOut
            }
            let state = try await group.next()!
            group.cancelAll()
            return state
        }
    }
}

private nonisolated final class SessionObservationTask: @unchecked Sendable {
    var value: Task<Void, Never>?
}
