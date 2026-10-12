import SwiftUI
import UIKit

nonisolated enum AuthoritativeMapTargetResolver {
    static func highlightedIDs(from choices: [GameCore.LegalChoice]) -> Set<String> {
        Set(choices.compactMap { targetID(for: $0.value) })
    }

    static func choice(
        for targetID: String,
        in choices: [GameCore.LegalChoice]
    ) -> GameCore.LegalChoice? {
        let matches = choices.filter { Self.targetID(for: $0.value) == targetID }
        // 同一地点可能有多个建造槽位:地图只有地点粒度,歧义时忽略点击,
        // 由底部带"位置 N"的按钮完成槽位选择,避免静默代选第一个槽位。
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    private static func targetID(for value: GameCore.LegalChoiceValue) -> String? {
        switch value {
        case .buildTarget(let locationID, _): locationID
        case .route(let routeID): routeID
        case .merchant(let slotID): slotID
        default: nil
        }
    }
}

struct AuthoritativeMatchBoardView: View {
    @Bindable var store: SessionViewStore
    @Environment(MotionPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var interaction = MatchInteractionReducer()
    @State private var selections: [GameCore.LegalChoiceValue] = []
    @State private var selectionLabels: [String] = []
    @State private var forcedSaleIDs: [String] = []
    @State private var autoAdvanceCount = 0
    @State private var cancelArmed = false
    @State private var marketExpanded = false
    @State private var lastSelectedChoiceID: String?
    @State private var lastSelectedChoiceAt: TimeInterval = 0
    @State private var showsActionLog = false
    @State private var railTwoEligible = false
    @State private var activeTurnNotice: ActiveTurnPresentation?
    @State private var activeTurnNoticeTracker = ActiveTurnNoticeTracker()

    private struct ActiveTurnNoticeTaskID: Hashable {
        let activePlayerID: String?
        let isSynchronized: Bool
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = MatchLayoutMetrics(
                viewport: proxy.size,
                safeAreaLeading: proxy.safeAreaInsets.leading,
                safeAreaTrailing: proxy.safeAreaInsets.trailing
            )
            if let snapshot = store.snapshot, let catalog = store.presentationCatalog {
                switch Result(catching: {
                    try RealMatchViewModel.make(
                        snapshot: snapshot, hostPlayerID: store.hostPlayerID, catalog: catalog
                    )
                }) {
                case .success(let state):
                    let activeTurn = ActiveTurnPresentation.make(
                        players: state.players,
                        localPlayerID: store.localPlayerID.rawValue
                    )
                    let noticeTaskID = ActiveTurnNoticeTaskID(
                        activePlayerID: activeTurn?.playerID,
                        isSynchronized: store.syncStatus == .synchronized
                    )
                    ZStack {
                    GameMapView(
                        state: state,
                        highlightedIDs: highlightedIDs,
                        onTargetTap: selectMapTarget,
                        onBackgroundTap: dismissTransientOverlay,
                        legendInsets: MapLegendInsets(
                            top: metrics.mapLegendInsetsWithinPaddedViewport.top,
                            trailing: metrics.mapLegendInsetsWithinPaddedViewport.trailing
                        ),
                        viewportInsets: metrics.mapViewportInsets
                    )
                    .padding(.top, metrics.mapTopInset)
                    .background(BrassColor.coal.color)
                    .ignoresSafeArea(
                        edges: metrics.formFactor == .phone
                            ? .horizontal
                            : [.horizontal, .bottom]
                    )

                    activeTurnNoticeLayer(metrics: metrics)
                    transientRailLayer(state: state, metrics: metrics)
                    leftRail(state: state, metrics: metrics)
                    rightRail(state: state, metrics: metrics)
                    header(state: state, activeTurn: activeTurn, metrics: metrics)
                    hand(state: state, metrics: metrics)
                    if metrics.marketPlacement == .bottomLeftCompact {
                        compactMarket(state: state, metrics: metrics)
                    }
                    actions(state: state, metrics: metrics)
                    retractTurnPill(metrics: metrics)
                    confirmTurnEndLayer(metrics: metrics)
                    actionContext(state: state, metrics: metrics)
                    legalChoices(metrics: metrics)
                    // 强制出售面板会全屏覆盖并自带确认键,不再渲染被遮住的标准确认面板。
                    if store.snapshot?.forcedSale == nil {
                        confirmation(state: state, metrics: metrics)
                    }
                    forcedSale(metrics: metrics)

                    // 时代结算确认:暂停操作,全员确认后进入铁路时代。
                    if let intermission = store.snapshot?.eraIntermission {
                        EraIntermissionView(
                            intermission: intermission,
                            projections: store.snapshot?.match?.players ?? [],
                            localPlayerID: store.localPlayerID.rawValue,
                            displayName: { store.displayName(for: $0) },
                            onConfirm: { store.confirmEraTransition() }
                        )
                        .transition(.opacity)
                    }

                    // 终局得分榜。
                    if let gameEnded = store.snapshot?.gameEnded {
                        FinalScoreboardView(
                            standings: gameEnded.standings,
                            projections: store.snapshot?.match?.players ?? [],
                            displayName: { store.displayName(for: $0) }
                        )
                        .transition(.opacity)
                    }

                    if store.syncStatus != .synchronized {
                        Color.black.opacity(0.35).ignoresSafeArea()
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("对局同步中，行动已暂停")
                            .accessibilityIdentifier("submission.blocker")
                    }
                    if let error = store.errorMessage {
                        Text(error)
                            .font(BrassTypography.label)
                            .foregroundStyle(BrassColor.paper.color)
                            .padding(12)
                            .background(BrassColor.danger.color)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.bottom, metrics.handHeight + 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .accessibilityIdentifier("real.recovery")
                    }
#if DEBUG
                    if store.showsRecoveryUIFixtureControl {
                        Button("推进恢复状态") { store.advanceRecoveryUIFixture() }
                            .buttonStyle(BrassPrimaryButtonStyle())
                            .padding(.trailing, metrics.rightRailWidth + 8)
                            .padding(.top, metrics.headerHeight + 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .accessibilityIdentifier("real.recovery.advance")
                    }
#endif
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .task(id: noticeTaskID) {
                        await presentActiveTurnNotice(activeTurn, taskID: noticeTaskID)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("real.match")
                case .failure:
                    Text("对局展示数据不可用，请返回房间后重试。")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(BrassColor.coal.color)
                        .foregroundStyle(BrassColor.paper.color)
                        .accessibilityIdentifier("real.match.presentationError")
                }
            } else {
                ProgressView("等待权威对局状态")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(BrassColor.coal.color)
                    .foregroundStyle(BrassColor.paper.color)
                    .accessibilityIdentifier("real.match.waiting")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsActionLog) {
            MatchActionLogView(
                entries: store.actionLog,
                playerLabel: { store.displayName(for: $0) },
                playerColor: { playerID in
                    let projection = store.snapshot?.match?.players
                        .first(where: { $0.id == playerID })
                    return MatchActionLogView.displayColor(projection?.color ?? .red)
                }
            )
        }
        .task(id: store.snapshot?.forcedSale) {
            forcedSaleIDs = []
            if store.snapshot?.forcedSale != nil {
                await store.requestForcedSaleOptions()
            }
        }
        .onChange(of: store.version) { oldVersion, newVersion in
            guard newVersion != oldVersion else { return }
            resetTransientSelectionState()
        }
        .onChange(of: store.errorMessage) { _, message in
            // 被拒/选择序列非法时,store 会清空 legalResponse 并给出错误提示;
            // 此时同步复位视图侧选择状态,避免残留造成僵尸态。
            // 注意:每步选择开始时 legalResponse 也会短暂为 nil,不能以此作为复位条件。
            guard message != nil, store.legalResponse == nil else { return }
            resetTransientSelectionState()
        }
        .onChange(of: store.legalResponse?.nextChoices) { _, choices in
            guard
                let response = store.legalResponse,
                response.error == nil,
                response.completePayload == nil,
                interaction.selectedAction != nil
            else { return }
            // 修路计数步:默认按“1 条铁路”静默前进,线路直接在地图上点;
            // 想修 2 条时用提示条上的“改修 2 条”回退改选。
            if response.nextChoices.allSatisfy({ choice in
                if case .networkLinkCount = choice.value { return true }
                return false
            }) {
                guard autoAdvanceCount < 8 else { return }
                autoAdvanceCount += 1
                railTwoEligible = response.nextChoices.contains { choice in
                    if case .networkLinkCount(2) = choice.value { return true }
                    return false
                }
                let single = response.nextChoices.first { choice in
                    if case .networkLinkCount(1) = choice.value { return true }
                    return false
                } ?? response.nextChoices[0]
                select(single, throttled: false)
                return
            }
            // 单选项步骤自动前进:煤/铁/酒来源唯一、"结束出售"等不再强制多点一下。
            guard
                response.nextChoices.count == 1,
                autoAdvanceCount < 8
            else { return }
            autoAdvanceCount += 1
            select(response.nextChoices[0], throttled: false)
        }
    }

    private func resetTransientSelectionState() {
        interaction.resetSelection()
        selections = []
        selectionLabels = []
        forcedSaleIDs = []
        autoAdvanceCount = 0
        railTwoEligible = false
        cancelArmed = false
    }

    private func compactMarket(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        ResourceMarketView(
            coal: state.coalMarket, iron: state.ironMarket,
            presentation: marketExpanded ? .overlay : .compact,
            reduceMotion: true,
            onExpand: { marketExpanded.toggle() }
        )
        .padding(.leading, metrics.leftRailWidth + 8)
        .padding(.bottom, metrics.handHeight + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: marketExpanded ? .center : .bottomLeading)
    }

    private func leftRail(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        VStack(spacing: 0) {
            if metrics.formFactor == .phone {
                Button {
                    toggleRailOverlay(.playerRail)
                } label: {
                    PlayerRailView(
                        players: state.players,
                        metrics: metrics,
                        localPlayerID: store.localPlayerID.rawValue,
                        accessibilityEnabled: false
                    )
                    .frame(height: phoneRailHeight(metrics: metrics))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PlayerRailView.accessibilitySummary(
                    players: state.players,
                    showsColorAssistSymbols: preferences.colorAssistEnabled,
                    localPlayerID: store.localPlayerID.rawValue
                ))
                .accessibilityValue(
                    "\(interaction.overlay == .playerRail ? "已展开" : "已收起")，\(PlayerRailView.railAccessibilityValue(players: state.players))"
                )
                .accessibilityIdentifier("real.playerRail.toggle")
            } else {
                PlayerRailView(
                    players: state.players,
                    metrics: metrics,
                    localPlayerID: store.localPlayerID.rawValue,
                    showsColorAssistSymbols: preferences.colorAssistEnabled
                )
            }
            if metrics.marketPlacement == .underPlayerRail {
                ResourceMarketView(
                    coal: state.coalMarket, iron: state.ironMarket,
                    presentation: .full, reduceMotion: true
                )
            }
        }
        .frame(width: metrics.leftRailWidth)
        .padding(.top, metrics.headerHeight + 8).padding(.bottom, metrics.handHeight + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func rightRail(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        Group {
            if metrics.formFactor == .phone {
                Button {
                    toggleRailOverlay(.industryRail)
                } label: {
                    IndustryRailView(
                        industries: state.industries,
                        metrics: metrics,
                        reduceMotion: true,
                        accessibilityEnabled: false
                    )
                    .frame(height: phoneRailHeight(metrics: metrics))
                    .clipped()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("产业板块，点按展开详情")
                .accessibilityValue(
                    interaction.overlay == .industryRail ? "已展开" : "已收起"
                )
                .accessibilityIdentifier("real.industryRail.toggle")
            } else {
                IndustryRailView(
                    industries: state.industries,
                    metrics: metrics,
                    reduceMotion: true
                )
            }
        }
            .padding(.top, metrics.headerHeight + 8).padding(.bottom, metrics.handHeight + 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private func phoneRailHeight(metrics: MatchLayoutMetrics) -> CGFloat {
        max(
            44,
            metrics.viewport.height - metrics.headerHeight - 8 - metrics.handHeight - 8
        )
    }

    @ViewBuilder
    private func transientRailLayer(
        state: DemoMatchState,
        metrics: MatchLayoutMetrics
    ) -> some View {
        if metrics.formFactor == .phone {
            switch interaction.overlay {
            case .playerRail:
                AuthoritativePlayerDrawer(
                    players: state.players,
                    localPlayerID: store.localPlayerID.rawValue,
                    showsColorAssistSymbols: preferences.colorAssistEnabled
                )
                .frame(width: MatchInteractionReducer.drawerWidth(
                    viewportWidth: metrics.viewport.width
                ))
                .padding(.leading, metrics.leftRailWidth)
                .padding(.top, metrics.headerHeight + 8)
                .padding(.bottom, metrics.handHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .transition(railTransition(edge: .leading))
            case .industryRail:
                AuthoritativeIndustryDrawer(industries: state.industries)
                    .frame(width: MatchInteractionReducer.drawerWidth(
                        viewportWidth: metrics.viewport.width
                    ))
                    .padding(.trailing, metrics.rightRailWidth)
                    .padding(.top, metrics.headerHeight + 8)
                    .padding(.bottom, metrics.handHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(railTransition(edge: .trailing))
            case .resourceMarket, .actionGrid, nil:
                EmptyView()
            }
        }
    }

    private func toggleRailOverlay(_ overlay: MatchOverlay) {
        withAnimation(railAnimation) {
            interaction.toggleOverlay(overlay)
        }
    }

    private func dismissTransientOverlay() {
        withAnimation(railAnimation) {
            interaction.dismissOverlay()
        }
    }

    private var railAnimation: Animation {
        preferences.reduceMotion || systemReduceMotion
            ? .easeOut(duration: 0.1)
            : .snappy(duration: 0.22)
    }

    private func railTransition(edge: Edge) -> AnyTransition {
        preferences.reduceMotion || systemReduceMotion
            ? .opacity
            : .move(edge: edge).combined(with: .opacity)
    }

    private func header(
        state: DemoMatchState,
        activeTurn: ActiveTurnPresentation?,
        metrics: MatchLayoutMetrics
    ) -> some View {
        MatchHeaderView(
            state: state,
            roomID: store.roomID.rawValue,
            syncStatus: store.syncStatus.rawValue,
            isSynchronized: store.syncStatus == .synchronized,
            activeTurn: activeTurn,
            metrics: metrics,
            onShowActionLog: { showsActionLog = true }
        )
        .padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 8)
        .frame(height: metrics.headerHeight)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func activeTurnNoticeLayer(metrics: MatchLayoutMetrics) -> some View {
        if let activeTurnNotice {
            ActiveTurnNoticeView(
                presentation: activeTurnNotice,
                reduceMotion: preferences.reduceMotion || systemReduceMotion
            )
            .allowsHitTesting(false)
            .padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 8)
            .padding(.top, metrics.headerHeight + 8)
            .padding(.bottom, metrics.handHeight + 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    @MainActor
    private func presentActiveTurnNotice(
        _ presentation: ActiveTurnPresentation?,
        taskID: ActiveTurnNoticeTaskID
    ) async {
        let shouldPresent = activeTurnNoticeTracker.consume(
            playerID: taskID.activePlayerID,
            isSynchronized: taskID.isSynchronized
        )
        guard shouldPresent, let presentation else {
            if !taskID.isSynchronized { activeTurnNotice = nil }
            return
        }

        let reduceMotion = preferences.reduceMotion || systemReduceMotion
        withAnimation(
            reduceMotion
                ? .easeOut(duration: 0.1)
                : .spring(response: 0.28, dampingFraction: 0.82)
        ) {
            activeTurnNotice = presentation
        }
        UIAccessibility.post(
            notification: .announcement,
            argument: presentation.accessibilityLabel
        )
        if presentation.isLocalPlayer && preferences.isHapticsEnabled {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        do {
            try await Task<Never, Never>.sleep(for: .milliseconds(1_200))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.2)) {
            activeTurnNotice = nil
        }
    }

    private func hand(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        HandView(
            cards: state.hand, formFactor: metrics.formFactor,
            selectedCardID: interaction.selectedCardID,
            scoutCardIDs: scoutChoiceCardIDs,
            selectedScoutCardIDs: selectedScoutCardIDs,
            onSelect: { id in
                if interaction.selectedAction == .scout {
                    selectScoutHandCard(id)
                    return
                }
                if interaction.selectedCardID == id {
                    // 再次点击当前卡:整段重置行动流,回到可重新选择行动的状态。
                    store.cancelLegalFlow()
                    resetTransientSelectionState()
                    return
                }
                store.selectCard(id)
                interaction.selectCard(id)
                selections = []
                selectionLabels = []
            }
        )
        .frame(height: metrics.handHeight)
        .padding(.leading, metrics.leftRailWidth + 8)
        .padding(.trailing, metrics.rightRailWidth + 8)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityIdentifier("real.hand")
    }

    private func actions(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        let actions = Set(store.availableActions.compactMap { GameAction(rawValue: $0.rawValue) })
        return Group {
            if interaction.selectedCardID != nil, interaction.selectedAction == nil {
                ActionGridView(
                    allowedActions: actions,
                    onSelect: { action in
                        interaction.selectAction(action)
                        selections = []
                        selectionLabels = []
                        autoAdvanceCount = 0
                        if let kind = GameCore.ActionKind(rawValue: action.rawValue) {
                            Task { await store.requestLegalOptions(action: kind) }
                        }
                    },
                    onClose: {
                        // 取消 = 连同选卡一起退出,回到"选择一张手牌"状态
                        interaction.resetSelection()
                        selections = []
                        selectionLabels = []
                        autoAdvanceCount = 0
                        store.cancelLegalFlow()
                    }
                )
            }
            // 设计稿 §8.4:建造不可行时给出具体原因与出路,而不是静默变灰。
            if interaction.selectedCardID != nil, interaction.selectedAction == nil,
               let cardID = interaction.selectedCardID,
               let hint = ActionBlockHint.buildReason(
                   state: state, cardID: cardID, localPlayerID: store.localPlayerID.rawValue
               ) {
                Text("⚠︎ 建造暂时不可用:\(hint)")
                    .font(BrassTypography.label)
                    .foregroundStyle(BrassColor.paper.color.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .background(BrassColor.coal.color.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, metrics.leftRailWidth + 8)
                    .padding(.trailing, metrics.rightRailWidth + 8)
                    .padding(.bottom, metrics.handHeight + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .accessibilityIdentifier("build.blocked.hint")
            }
        }
        .padding(.trailing, metrics.rightRailWidth + 8)
        .padding(.bottom, metrics.handHeight + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    /// 撤回本回合已落地的全部操作(回到回合开始):自己回合、已有行动、
    /// 未处于选牌/查询流程时显示。
    @ViewBuilder
    private func retractTurnPill(metrics: MatchLayoutMetrics) -> some View {
        if store.canRetractTurnActions, interaction.selectedCardID == nil {
            Button {
                interaction.resetSelection()
                store.cancelLegalFlow()
                store.retractTurnActions()
            } label: {
                Label(
                    "撤回本回合操作",
                    systemImage: "arrow.uturn.backward.circle.fill"
                )
                .font(BrassTypography.label)
                .foregroundStyle(BrassColor.paper.color)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(BrassColor.brass.color, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("match.retractTurnActions")
            // 右下角:与左下的紧凑材料面板错开;仅在未选牌时显示,
            // 而右下的操作菜单只在选牌后出现,二者不会同屏。
            .padding(.trailing, metrics.rightRailWidth + 8)
            .padding(.bottom, metrics.handHeight + 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    /// 回合结束待确认:自己两个行动落地后,点击确认才过轮(期间仍可撤回);
    /// 他人待确认时顶部提示等待。
    @ViewBuilder
    private func confirmTurnEndLayer(metrics: MatchLayoutMetrics) -> some View {
        if store.isAwaitingTurnEndConfirmation {
            if store.canConfirmTurnEnd, interaction.selectedCardID == nil {
                VStack(spacing: 8) {
                    Button {
                        interaction.resetSelection()
                        store.cancelLegalFlow()
                        store.confirmTurnEnd()
                    } label: {
                        Label(
                            "确认结束回合",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(BrassTypography.title)
                        .foregroundStyle(BrassColor.coal.color)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(BrassColor.brass.color, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("match.confirmTurnEnd")
                    Text("两个行动已完成,确认后交给下一位;仍可撤回重下")
                        .font(BrassTypography.label)
                        .foregroundStyle(BrassColor.paper.color.opacity(0.92))
                }
                // 屏幕中下方居中:不与右下撤回胶囊、底部手牌区重叠。
                .padding(.bottom, metrics.handHeight + 56)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            } else if store.snapshot?.activePlayerID != store.localPlayerID {
                Text("等待 \(store.displayName(for: store.snapshot?.activePlayerID ?? store.localPlayerID)) 确认结束回合…")
                    .font(BrassTypography.label)
                    .foregroundStyle(BrassColor.paper.color.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(BrassColor.coal.color.opacity(0.88), in: Capsule())
                    .accessibilityIdentifier("match.awaitingTurnEndNotice")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 64)
            }
        }
    }

    @ViewBuilder
    private func actionContext(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        if let action = interaction.selectedAction,
           let match = store.snapshot?.match,
           let progress = ActionContextProgress(
               era: match.era,
               roundNumber: match.roundNumber,
               actionsRemaining: match.actionsRemaining
           ) {
            ActionContextBar(
                currentActionNumber: progress.current,
                totalActions: progress.total,
                action: action,
                instruction: ActionContextBar.instruction(
                    for: action,
                    selectionLabels: selectionLabels,
                    choices: store.legalResponse?.nextChoices ?? []
                ),
                hint: nil,
                canUndo: selectionLabels.isEmpty == false,
                cancelArmed: cancelArmed,
                onUndo: undoLastSelection,
                onCancel: handleCancel
            )
            .padding(.leading, metrics.leftRailWidth + 8)
            .padding(.trailing, metrics.rightRailWidth + 8)
            .padding(.bottom, metrics.handHeight + 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    @ViewBuilder
    private func legalChoices(metrics: MatchLayoutMetrics) -> some View {
        if let response = store.legalResponse, !response.nextChoices.isEmpty {
            // 修路步骤不弹选项:线路已高亮,直接在地图上点选。
            if routeStepActive {
                HStack(spacing: 12) {
                    Label("在地图上点选要修的铁路", systemImage: "hand.tap.fill")
                        .font(BrassTypography.label)
                        .foregroundStyle(BrassColor.paper.color)
                    if canUpgradeToTwoRails {
                        Button("改修 2 条") { upgradeToTwoRails() }
                            .font(BrassTypography.label)
                            .foregroundStyle(BrassColor.coal.color)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .background(BrassColor.brass.color)
                            .clipShape(Capsule())
                            .accessibilityIdentifier("network.twoRail.toggle")
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .background(BrassColor.coal.color.opacity(0.94))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 12)
                .padding(.bottom, bottomActionOverlayInset(metrics: metrics))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .accessibilityIdentifier("network.mapPickHint")
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(response.nextChoices, id: \.id) { choice in
                            Button(choice.label) { select(choice) }
                                .buttonStyle(BrassPrimaryButtonStyle())
                                .accessibilityIdentifier("legal.choice.\(choice.id)")
                        }
                    }.padding(8)
                }
                .background(BrassColor.coal.color.opacity(0.94))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 12)
                .padding(.bottom, bottomActionOverlayInset(metrics: metrics))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .accessibilityIdentifier("legal.choices")
            }
        }
    }

    /// 当前是否处于“点选线路”步骤。
    private var routeStepActive: Bool {
        store.legalResponse?.nextChoices.contains { choice in
            if case .route = choice.value { return true }
            return false
        } ?? false
    }

    /// 尚未点任何线路、且引擎提供了 2 条铁路的资格时,允许回退改选 2 条。
    private var canUpgradeToTwoRails: Bool {
        guard railTwoEligible else { return false }
        if case .networkLinkCount(1) = selections.last { return true }
        return false
    }

    private func upgradeToTwoRails() {
        guard canUpgradeToTwoRails else { return }
        selections.removeLast()
        if selectionLabels.isEmpty == false { selectionLabels.removeLast() }
        railTwoEligible = false
        select(
            .init(id: "network-count:2", label: "2 条铁路", value: .networkLinkCount(2)),
            throttled: false
        )
    }

    @ViewBuilder
    private func confirmation(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        if let response = store.legalResponse,
           response.completePayload != nil,
           let delta = response.confirmation {
            let current = store.snapshot?.match?.players.first(where: { $0.id == store.localPlayerID })
            ConfirmationPanel(
                title: "确认行动",
                instruction: "由房主规则引擎验证；提交后等待权威事件",
                details: selectionLabels,
                summary: .init(
                    discardedCard: interaction.selectedCardID ?? "",
                    moneyDelta: delta.cashDelta,
                    coalDelta: resourceDelta(.coal, in: delta.resourceEffects),
                    ironDelta: resourceDelta(.iron, in: delta.resourceEffects),
                    beerDelta: resourceDelta(.beer, in: delta.resourceEffects),
                    // 收入展示一律换算成收入等级(£):incomeDelta 是"格数",
                    // 格≠钱(0~10 每 2 格 £1,10~20 每 3 格 £1,20~30 每 4 格 £1)。
                    incomeBefore: current?.incomeLevel,
                    incomeAfter: current.flatMap {
                        Self.incomeLevel(at: $0.incomePosition + delta.incomeDelta)
                    },
                    moneyBefore: current?.cash,
                    moneyAfter: current.map { $0.cash + delta.cashDelta }
                ),
                previewItems: [], incomeAccessibilityIdentifier: "action.beforeAfter.income",
                isConfirmEnabled: store.canInteract,
                onConfirm: { Task { await store.submitCompleteLegalResponse() } },
                onCancel: cancelActionFlow
            )
            .padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 12)
            .padding(.bottom, bottomActionOverlayInset(metrics: metrics))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// 捆绑收入轨的"格 → 收入等级(£)"映射,与 GameCore 校验过的数据同源。
    private static let incomeLevelsByPosition: [Int: Int] = {
        guard let url = Bundle.main.url(forResource: "income-track", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let track = try? JSONDecoder().decode(GameCore.IncomeTrack.self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: track.entries.map { ($0.position, $0.income) })
    }()

    /// 格索引换算收入等级;越界时钳制到轨端点(引擎推进同样在轨端封顶)。
    private static func incomeLevel(at position: Int) -> Int? {
        guard let lowest = incomeLevelsByPosition.keys.min(),
              let highest = incomeLevelsByPosition.keys.max()
        else { return nil }
        return incomeLevelsByPosition[min(max(position, lowest), highest)]
    }

    private func resourceDelta(
        _ resource: GameCore.ResourceKind,
        in effects: [GameCore.ResourceEffect]
    ) -> Int {
        -effects.filter {
            if case .resourceRemoved(let removed, _, _) = $0 { removed == resource }
            else { false }
        }.count
    }

    @ViewBuilder
    private func forcedSale(metrics: MatchLayoutMetrics) -> some View {
        if let forcedSale = store.snapshot?.forcedSale {
            VStack(spacing: 8) {
                Text("需出售产业弥补 £\(forcedSale.shortfall)")
                    .font(BrassTypography.title).foregroundStyle(BrassColor.paper.color)
                ForEach(forcedSale.eligiblePlacementIDs, id: \.self) { id in
                    Button {
                        if let index = forcedSaleIDs.firstIndex(of: id) {
                            forcedSaleIDs.removeSubrange(index...)
                        } else {
                            forcedSaleIDs.append(id)
                        }
                        Task { await store.requestForcedSaleOptions(placementIDs: forcedSaleIDs) }
                    } label: {
                        let value = forcedSale.options.first(where: { $0.placementID == id })?.liquidationValue
                        Label(
                            forcedSaleLabel(placementID: id, value: value),
                            systemImage: forcedSaleIDs.contains(id) ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    .buttonStyle(BrassPrimaryButtonStyle())
                    // 已凑足后禁止继续勾选未选项(仍可反勾已选项);引擎侧会拒绝超额前缀。
                    .disabled(store.legalResponse?.completePayload != nil
                              && forcedSaleIDs.contains(id) == false)
                    .accessibilityIdentifier("forcedSale.\(id)")
                }
                Button("确认出售") {
                    Task { await store.submitForcedSale() }
                }
                .buttonStyle(BrassPrimaryButtonStyle())
                .disabled({
                    guard case .forcedSale = store.legalResponse?.completePayload else { return true }
                    return false
                }())
                .accessibilityIdentifier("forcedSale.confirm")
            }
            .brassPanel().padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let debtor = store.snapshot?.match?.forcedSaleDebtorID {
            Text("\(debtor.rawValue) 正在处理强制出售，对局已暂停")
                .font(BrassTypography.title)
                .foregroundStyle(BrassColor.paper.color)
                .brassPanel()
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("forcedSale.paused")
        }
    }

    private var highlightedIDs: Set<String> {
        AuthoritativeMapTargetResolver.highlightedIDs(
            from: store.legalResponse?.nextChoices ?? []
        )
    }

    private func selectMapTarget(_ id: String) {
        guard let choice = AuthoritativeMapTargetResolver.choice(
            for: id,
            in: store.legalResponse?.nextChoices ?? []
        ) else { return }
        select(choice)
    }

    private func select(_ choice: GameCore.LegalChoice, throttled: Bool = true) {
        // 节流防双击:同一选项在短窗口内的重复点击忽略(自动前进链不受限)。
        // 注意不能用"值相同"判断——引擎允许连续从同一煤矿/酒厂取资源。
        let now = Date().timeIntervalSince1970
        if throttled, choice.id == lastSelectedChoiceID, now - lastSelectedChoiceAt < 0.35 {
            return
        }
        lastSelectedChoiceID = choice.id
        lastSelectedChoiceAt = now
        selections.append(choice.value)
        selectionLabels.append(choice.label)
        requestLegalOptionsForSelectedAction()
    }

    private func selectScoutHandCard(_ id: String) {
        if let index = selections.firstIndex(where: { value in
            guard case .card(let cardID) = value else { return false }
            return cardID == id
        }) {
            selections.remove(at: index)
            if selectionLabels.indices.contains(index) {
                selectionLabels.remove(at: index)
            }
            requestLegalOptionsForSelectedAction()
            return
        }

        guard let choice = scoutChoice(for: id) else { return }
        selections.append(choice.value)
        selectionLabels.append(choice.label)
        requestLegalOptionsForSelectedAction()
    }

    private func requestLegalOptionsForSelectedAction() {
        guard let action = interaction.selectedAction,
              let kind = GameCore.ActionKind(rawValue: action.rawValue) else { return }
        Task { await store.requestLegalOptions(action: kind, selections: selections) }
    }

    private func cancelActionFlow() {
        interaction.cancelFlow()
        selections = []
        selectionLabels = []
        store.cancelLegalFlow()
    }

    /// 误触保护:选择序列较长时,X 第一次按下只进入"确认取消"状态。
    private func handleCancel() {
        if selections.count >= 2, !cancelArmed {
            cancelArmed = true
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                cancelArmed = false
            }
        } else {
            cancelArmed = false
            cancelActionFlow()
        }
    }

    /// 撤销上一步选择:丢弃最后一个选择值并重新查询,误选不再需要整段重来。
    private func undoLastSelection() {
        guard selections.isEmpty == false else { return }
        selections.removeLast()
        if selectionLabels.isEmpty == false { selectionLabels.removeLast() }
        requestLegalOptionsForSelectedAction()
    }

    private func bottomActionOverlayInset(metrics: MatchLayoutMetrics) -> CGFloat {
        metrics.handHeight + (interaction.selectedAction == nil ? 8 : 58)
    }

    private var scoutChoiceCardIDs: Set<String> {
        Set((store.legalResponse?.nextChoices ?? []).compactMap { choice in
            guard case .card(let id) = choice.value else { return nil }
            return id
        })
    }

    private var selectedScoutCardIDs: Set<String> {
        Set(selections.compactMap { value in
            guard case .card(let id) = value else { return nil }
            return id
        })
    }

    private func scoutChoice(for id: String) -> GameCore.LegalChoice? {
        (store.legalResponse?.nextChoices ?? []).first { choice in
            guard case .card(let cardID) = choice.value else { return false }
            return cardID == id
        }
    }

    private func forcedSaleLabel(placementID: String, value: Int?) -> String {
        let placement = store.snapshot?.match?.boardIndustryPlacements.first {
            $0.placementID == placementID
        }
        let title = placement.map {
            "\(RealMatchViewModel.industryTitle($0.tile.industryDefinitionID)) L\($0.tile.level)"
        } ?? "产业"
        return value.map { "\(title) · £\($0)" } ?? title
    }
}
