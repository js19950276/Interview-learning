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
        choices.first { Self.targetID(for: $0.value) == targetID }
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
                    actionContext(state: state, metrics: metrics)
                    legalChoices(metrics: metrics)
                    confirmation(state: state, metrics: metrics)
                    forcedSale(metrics: metrics)

                    if store.syncStatus != .synchronized {
                        Color.black.opacity(0.35).ignoresSafeArea()
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
        .task(id: store.snapshot?.forcedSale) {
            forcedSaleIDs = []
            if store.snapshot?.forcedSale != nil {
                await store.requestForcedSaleOptions()
            }
        }
        .onChange(of: store.version) { oldVersion, newVersion in
            guard newVersion != oldVersion else { return }
            interaction.resetSelection()
            selections = []
            selectionLabels = []
            forcedSaleIDs = []
        }
    }

    private func compactMarket(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        ResourceMarketView(
            coal: state.coalMarket, iron: state.ironMarket,
            presentation: .compact, reduceMotion: true
        )
        .padding(.leading, metrics.leftRailWidth + 8)
        .padding(.bottom, metrics.handHeight + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
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
            metrics: metrics
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
                        if let kind = GameCore.ActionKind(rawValue: action.rawValue) {
                            Task { await store.requestLegalOptions(action: kind) }
                        }
                    },
                    onClose: {
                        interaction.cancelFlow()
                        selections = []
                        selectionLabels = []
                        store.cancelLegalFlow()
                    }
                )
            }
        }
        .padding(.trailing, metrics.rightRailWidth + 8)
        .padding(.bottom, metrics.handHeight + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
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
                onCancel: cancelActionFlow
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
                    incomeBefore: current?.incomePosition,
                    incomeAfter: current.map { $0.incomePosition + delta.incomeDelta },
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

    private func select(_ choice: GameCore.LegalChoice) {
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
