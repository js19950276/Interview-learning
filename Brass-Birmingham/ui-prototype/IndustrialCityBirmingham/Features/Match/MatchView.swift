import SwiftUI
import UIKit

struct RealMatchView: View {
    @Bindable var store: SessionViewStore

    var body: some View {
        AuthoritativeMatchBoardView(store: store)
    }

#if DEBUG
    private var legacyDebugPreviewBody: some View {
        GeometryReader { proxy in
            let metrics = MatchLayoutMetrics(
                viewport: proxy.size,
                safeAreaTrailing: proxy.safeAreaInsets.trailing
            )
            let preview = Self.debugBoardPlaceholder
            ZStack {
                GameMapView(state: preview, highlightedIDs: [], onTargetTap: { _ in }, onBackgroundTap: {},
                            accessibilityEnabled: false, legendInsets: metrics.mapLegendInsets)
                    .background(BrassColor.coal.color).ignoresSafeArea()
                    .accessibilityLabel("地图静态预览，仅支持平移缩放")

                VStack(spacing: 0) {
                    PlayerRailView(players: preview.players, metrics: metrics, accessibilityEnabled: false)
                    if metrics.marketPlacement == .underPlayerRail {
                        ResourceMarketView(coal: preview.coalMarket, iron: preview.ironMarket,
                                           presentation: .full, reduceMotion: true, accessibilityEnabled: false)
                    }
                }
                .allowsHitTesting(false).opacity(0.76)
                .accessibilityElement(children: .ignore)
                .accessibilityHidden(true)
                .accessibilityRepresentation { EmptyView() }
                .frame(width: metrics.leftRailWidth).padding(.top, 52).padding(.bottom, metrics.handHeight + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                IndustryRailView(industries: preview.industries, metrics: metrics, reduceMotion: true,
                                 accessibilityEnabled: false)
                    .allowsHitTesting(false).opacity(0.76)
                    .accessibilityElement(children: .ignore)
                    .accessibilityHidden(true)
                    .accessibilityRepresentation { EmptyView() }
                    .padding(.top, 52).padding(.bottom, metrics.handHeight + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

                if metrics.marketPlacement == .bottomLeftCompact {
                    ResourceMarketView(coal: preview.coalMarket, iron: preview.ironMarket,
                                       presentation: .compact, reduceMotion: true, accessibilityEnabled: false)
                        .allowsHitTesting(false).padding(.leading, metrics.leftRailWidth + 8)
                        .accessibilityElement(children: .ignore)
                        .accessibilityHidden(true)
                        .accessibilityRepresentation { EmptyView() }
                        .padding(.bottom, metrics.handHeight + 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }

                authoritativeHeader(metrics: metrics)
                authoritativePlayers(metrics: metrics)
                authoritativeHand(metrics: metrics)
                realActionGrid(metrics: metrics)
                if let error = store.errorMessage {
                    Text(error).foregroundStyle(BrassColor.paper.color).padding().background(BrassColor.danger.color)
                        .accessibilityIdentifier("real.recovery")
                        .padding(.bottom, metrics.handHeight + 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("real.match")
    }

    private func authoritativeHeader(metrics: MatchLayoutMetrics) -> some View {
        HStack(spacing: 12) {
            Text("房间 \(store.roomID.rawValue)").accessibilityIdentifier("real.room")
            Text("回合 \(store.snapshot?.turn ?? 0) · 行动 \(store.snapshot?.actionNumber ?? 0) · v\(store.version.rawValue)")
                .accessibilityIdentifier("real.turn")
            Spacer()
            Label(store.syncStatus.rawValue, systemImage: store.syncStatus == .synchronized ? "checkmark.icloud" : "arrow.triangle.2.circlepath")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(store.syncStatus.rawValue)
                .accessibilityIdentifier("real.sync")
            Text("地图、煤铁市场、产业为静态预览，规则待验证").font(.caption.bold())
                .accessibilityIdentifier("real.previewNotice")
        }
        .foregroundStyle(BrassColor.paper.color).brassPanel().padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 8)
        .padding(.top, 4).frame(maxHeight: .infinity, alignment: .top)
    }

    private func authoritativePlayers(metrics: MatchLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("真实席位").font(.caption.bold())
            ForEach(store.players, id: \.self) { player in
                let count = store.snapshot?.players.first(where: { $0.id == player })?.handCount ?? 0
                Text("\(player.rawValue) · \(count) 张\(store.snapshot?.activePlayerID == player ? " · 当前" : "")")
            }
        }
        .font(.caption2).foregroundStyle(BrassColor.paper.color).brassPanel()
        .accessibilityElement(children: .contain).accessibilityIdentifier("real.players")
        .padding(.leading, metrics.leftRailWidth + 8).padding(.top, 58)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func authoritativeHand(metrics: MatchLayoutMetrics) -> some View {
        HandView(cards: store.hand.map {
            HandCard(id: $0, title: $0, kind: .wildLocation, allowedActions: [.pass])
        }, formFactor: metrics.formFactor, selectedCardID: store.selectedCardID,
                 scoutCardIDs: [], selectedScoutCardIDs: [], onSelect: store.selectCard)
            .frame(height: metrics.handHeight).padding(.leading, metrics.leftRailWidth + 8)
            .padding(.trailing, metrics.rightRailWidth + 8)
            .frame(maxHeight: .infinity, alignment: .bottom).accessibilityIdentifier("real.hand")
    }

    private func realActionGrid(metrics: MatchLayoutMetrics) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("规则模块待验证").font(.caption.bold()).foregroundStyle(BrassColor.paper.color)
            ActionGridView(allowedActions: store.canSubmitPass ? [.pass] : [], onSelect: { action in
                guard action == .pass else { return }
                Task { await store.submitPass() }
            }, onClose: {})
            Button("过牌") { Task { await store.submitPass() } }
                .buttonStyle(BrassPrimaryButtonStyle()).disabled(!store.canSubmitPass)
                .accessibilityIdentifier("real.pass")
#if DEBUG
            if store.showsRecoveryUIFixtureControl {
                Button("推进恢复状态") { store.advanceRecoveryUIFixture() }
                    .buttonStyle(BrassPrimaryButtonStyle())
                    .accessibilityIdentifier("real.recovery.advance")
            }
#endif
        }
        .padding(.trailing, metrics.rightRailWidth + 8).padding(.bottom, metrics.handHeight + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private static let debugBoardPlaceholder = DemoMatchState(
        era: "静态预览", round: 0, roundCount: 0, actionNumber: 0, deckRemaining: 0,
        money: 0, income: 0, victoryPoints: 0,
        players: (0..<4).map { index in
            PlayerSummary(id: "preview-\(index)", name: "预览", color: PlayerColor.allCases[index], order: index + 1,
                          spent: 0, isCurrent: false, isHost: false, isReady: false, isConnected: false)
        },
        industries: IndustryKind.allCases.map {
            IndustrySummary(id: "preview-\($0.rawValue)", kind: $0, level: 0, cost: 0, coalCost: 0,
                            ironCost: 0, isAvailable: false)
        },
        coalMarket: .init(remaining: 0, cheapestPrice: 0, ladder: []),
        ironMarket: .init(remaining: 0, cheapestPrice: 0, ladder: []), hand: [],
        locations: [
            .init(id: "birmingham", name: "Birmingham", x: 0.50, y: 0.54),
            .init(id: "coventry", name: "Coventry", x: 0.70, y: 0.60),
            .init(id: "walsall", name: "Walsall", x: 0.45, y: 0.34),
            .init(id: "worcester", name: "Worcester", x: 0.35, y: 0.78)
        ],
        routes: [
            .init(id: "preview-b-c", fromLocationID: "birmingham", toLocationID: "coventry"),
            .init(id: "preview-b-w", fromLocationID: "birmingham", toLocationID: "walsall"),
            .init(id: "preview-b-wo", fromLocationID: "birmingham", toLocationID: "worcester")
        ]
    )
#endif
}

#if DEBUG
struct MatchView: View {
    @Environment(DemoSessionStore.self) private var store
    @Environment(MotionPreferences.self) private var preferences
    @State private var interaction: MatchInteractionReducer
    @State private var renderedState: DemoMatchState?
    @State private var acceptedEvent: DemoEvent?
    @State private var feedbackPlan: DemoFeedbackPlan?
    @State private var rejection: RejectedIntent?
    @State private var rejectionPlan: DemoRejectionFeedbackPlan?
    @State private var technicalFailure: TechnicalSubmissionFailure?
    @State private var technicalFailurePlan: DemoTechnicalFailureFeedbackPlan?
    @State private var submissionGate = DemoSubmissionGate()
    @State private var isSubmitting = false
    @State private var resourceMotionDestinationIDs: Set<String> = []
    @State private var submissionTask: Task<Void, Never>?
    @State private var resourceAnimationTask: Task<Void, Never>?
    @State private var hapticTask: Task<Void, Never>?
    @State private var renderAcknowledgements = PrototypeRenderAcknowledgementTracker()
    @AccessibilityFocusState private var isRejectionFocused: Bool
    @AccessibilityFocusState private var isTechnicalFailureFocused: Bool

    let playerCount: Int
    let initialState: DemoMatchInitialState

    init(playerCount: Int, initialState: DemoMatchInitialState = .standard) {
        self.playerCount = playerCount
        self.initialState = initialState

        let interaction = MatchInteractionReducer()
        if let selectedCardID = initialState.selectedCardID {
            interaction.selectCard(selectedCardID)
        }
        if let selectedAction = initialState.selectedAction {
            interaction.selectAction(selectedAction)
        }
        if let buildLocationID = initialState.buildLocationID {
            interaction.selectBuildLocation(buildLocationID, fixture: .standard)
        }
        _interaction = State(initialValue: interaction)
        _rejection = State(initialValue: initialState.rejection)
        _rejectionPlan = State(
            initialValue: initialState.rejection.map(DemoRejectionFeedbackPlan.make)
        )
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let metrics = MatchLayoutMetrics(
                    viewport: proxy.size,
                    safeAreaTrailing: proxy.safeAreaInsets.trailing
                )
                let state = fixtureState(
                    renderedState ?? store.match ?? DemoFixture.match(playerCount: playerCount)
                )
                let highlightedIDs = interaction.highlightedTargetIDs(
                    fixture: .standard,
                    routes: state.routes
                )

                ZStack {
                    GameMapView(
                        state: state,
                        highlightedIDs: highlightedIDs,
                        onTargetTap: { selectMapTarget($0, state: state) },
                        onBackgroundTap: interaction.dismissOverlay,
                        legendInsets: metrics.mapLegendInsets
                    )
                    .background(BrassColor.coal.color)
                    .ignoresSafeArea(
                        edges: metrics.formFactor == .phone ? .horizontal : .all
                    )
                    .allowsHitTesting(isSubmitting == false)
                    .prototypeRenderAcknowledgement(
                        renderAcknowledgements.ticket(for: .targetGlow),
                        tracker: renderAcknowledgements
                    )

                    transientMapLayer(state: state, metrics: metrics)
                        .allowsHitTesting(isSubmitting == false)
                        .prototypeRenderAcknowledgement(
                            renderAcknowledgements.ticket(for: .drawerResponse),
                            tracker: renderAcknowledgements
                        )
                    playerRail(state: state, metrics: metrics)
                        .allowsHitTesting(isSubmitting == false)
                    industryRail(state: state, metrics: metrics)
                        .allowsHitTesting(isSubmitting == false)
                    header(state: state, metrics: metrics)
                    hand(state: state, metrics: metrics)
                        .allowsHitTesting(isSubmitting == false)

                    if metrics.marketPlacement == .bottomLeftCompact {
                        compactMarket(state: state, metrics: metrics)
                            .allowsHitTesting(isSubmitting == false)
                    }

                    actionGrid(state: state, metrics: metrics)
                        .allowsHitTesting(isSubmitting == false)
                    actionButton(metrics: metrics)
                        .allowsHitTesting(isSubmitting == false)
                    actionFlow(state: state, metrics: metrics)
                        .allowsHitTesting(isSubmitting == false)
                    eventFeedback(metrics: metrics)
                    rejectionFeedback(metrics: metrics)
                    technicalFailureFeedback(metrics: metrics)

                    if isSubmitting {
                        Color.clear
                            .contentShape(Rectangle())
                            .ignoresSafeArea()
                            .onTapGesture {}
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("正在提交行动")
                            .accessibilityIdentifier("submission.blocker")
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(BrassColor.coal.color)
                .clipped()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("match.shell")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if rejectionPlan?.shouldFocus == true {
                isRejectionFocused = true
            }
        }
        .onDisappear(perform: cancelSubmissionAndFeedbackTasks)
    }

    private func fixtureState(_ state: DemoMatchState) -> DemoMatchState {
        guard let disconnectedPlayerID = initialState.disconnectedPlayerID else { return state }
        var disconnected = state
        if let index = disconnected.players.firstIndex(where: { $0.id == disconnectedPlayerID }) {
            disconnected.players[index].isConnected = false
        }
        return disconnected
    }

    private func playerRail(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        VStack(spacing: 0) {
            if metrics.formFactor == .phone {
                Button {
                    toggleMeasuredOverlay(.playerRail)
                } label: {
                    PlayerRailView(
                        players: state.players,
                        metrics: metrics,
                        showsColorAssistSymbols: preferences.colorAssistEnabled
                    )
                }
                .buttonStyle(.plain)
                .frame(height: phoneRailHeight(metrics: metrics))
                .accessibilityLabel(PlayerRailView.accessibilitySummary(
                    players: state.players,
                    showsColorAssistSymbols: preferences.colorAssistEnabled
                ))
                .accessibilityValue("\(state.players.count) 位玩家")
                .accessibilityIdentifier("match.playerRail")
            } else {
                PlayerRailView(
                    players: state.players,
                    metrics: metrics,
                    showsColorAssistSymbols: preferences.colorAssistEnabled
                )
                .frame(maxHeight: .infinity)
                .accessibilityLabel(PlayerRailView.accessibilitySummary(
                    players: state.players,
                    showsColorAssistSymbols: preferences.colorAssistEnabled
                ))
                .accessibilityValue("\(state.players.count) 位玩家")
                .accessibilityIdentifier("match.playerRail")
            }

            if metrics.marketPlacement == .underPlayerRail {
                ResourceMarketView(
                    coal: state.coalMarket,
                    iron: state.ironMarket,
                    presentation: .full,
                    reduceMotion: marketReduceMotion
                )
                .prototypeRenderAcknowledgement(
                    renderAcknowledgements.ticket(for: .marketUpdate),
                    tracker: renderAcknowledgements
                )
            }
        }
        .frame(width: metrics.leftRailWidth)
        .frame(maxHeight: metrics.formFactor == .tablet ? .infinity : nil)
        .padding(.top, metrics.headerHeight + 8)
        .padding(.bottom, metrics.handHeight + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func industryRail(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        Group {
            if metrics.formFactor == .phone && industrySelectionIsActive == false {
                Button {
                    toggleMeasuredOverlay(.industryRail)
                } label: {
                    industryRailContent(state: state, metrics: metrics)
                        .frame(height: phoneRailHeight(metrics: metrics), alignment: .top)
                        .clipped()
                }
                .buttonStyle(.plain)
                .frame(height: phoneRailHeight(metrics: metrics))
                .accessibilityLabel("展开产业板块")
                .accessibilityIdentifier("match.industryRail")
            } else if metrics.formFactor == .phone {
                ScrollView(.vertical) {
                    industryRailContent(state: state, metrics: metrics)
                }
                .scrollIndicators(.hidden)
                .frame(height: phoneRailHeight(metrics: metrics))
            } else {
                industryRailContent(state: state, metrics: metrics)
            }
        }
            .frame(maxHeight: metrics.formFactor == .tablet ? .infinity : nil)
            .padding(.top, metrics.headerHeight + 8)
            .padding(.bottom, metrics.handHeight + 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .overlay(alignment: .topTrailing) {
                if metrics.formFactor == .tablet {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("产业板块")
                        .accessibilityIdentifier("match.industryRail")
                        .allowsHitTesting(false)
                }
            }
    }

    private func phoneRailHeight(metrics: MatchLayoutMetrics) -> CGFloat {
        max(
            44,
            metrics.viewport.height - metrics.headerHeight - 8 - metrics.handHeight - 8
        )
    }

    private var industrySelectionIsActive: Bool {
        switch interaction.flow {
        case .develop, .sell:
            true
        case .idle, .build, .network, .loan, .scout, .pass:
            false
        }
    }

    private func industryRailContent(
        state: DemoMatchState,
        metrics: MatchLayoutMetrics
    ) -> IndustryRailView {
        switch interaction.flow {
        case .develop(let draft):
            IndustryRailView(
                industries: state.industries,
                metrics: metrics,
                selectableIndustryIDs: Set(ActionFixture.standard.developIndustryIDs),
                selectedIndustryIDs: Set(draft.industryIDs),
                selectionCountText: "\(draft.industryIDs.count)/2",
                flippedIndustryIDs: feedbackPlan?.flippedIndustryIDs ?? [],
                reduceMotion: effectiveReduceMotion,
                onSelectIndustry: {
                    interaction.toggleDevelopIndustry($0, fixture: .standard)
                }
            )
        case .sell(let draft):
            IndustryRailView(
                industries: state.industries,
                metrics: metrics,
                selectableIndustryIDs: Set(ActionFixture.standard.sellOptions.map(\.industryID)),
                selectedIndustryIDs: Set([draft.focusedIndustryID].compactMap { $0 }),
                flippedIndustryIDs: feedbackPlan?.flippedIndustryIDs ?? [],
                reduceMotion: effectiveReduceMotion,
                onSelectIndustry: {
                    interaction.selectSaleIndustry($0, fixture: .standard)
                }
            )
        case .idle, .build, .network, .loan, .scout, .pass:
            IndustryRailView(
                industries: state.industries,
                metrics: metrics,
                flippedIndustryIDs: feedbackPlan?.flippedIndustryIDs ?? [],
                reduceMotion: effectiveReduceMotion
            )
        }
    }

    private func header(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        MatchHeaderView(state: state)
            .padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 8)
            .padding(.top, 4)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private func hand(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        let scoutDraft: ScoutDraft? = if case .scout(let draft) = interaction.flow {
            draft
        } else {
            nil
        }

        return HandView(
            cards: state.hand,
            formFactor: metrics.formFactor,
            selectedCardID: interaction.selectedCardID,
            scoutCardIDs: scoutDraft == nil ? [] : Set(ActionFixture.standard.scoutCardIDs),
            selectedScoutCardIDs: Set(scoutDraft?.extraCardIDs ?? []),
            onSelect: { id in
                if scoutDraft != nil {
                    interaction.toggleScoutCard(id, fixture: .standard)
                } else {
                    measureRenderedResponse(.cardResponse) {
                        interaction.selectCard(id)
                    }
                }
            }
        )
            .frame(height: metrics.handHeight)
            .padding(.leading, metrics.leftRailWidth + 8)
            .padding(.trailing, metrics.rightRailWidth + 8)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .accessibilityIdentifier("match.hand")
            .prototypeRenderAcknowledgement(
                renderAcknowledgements.ticket(for: .cardResponse),
                tracker: renderAcknowledgements
            )
    }

    private func compactMarket(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        ResourceMarketView(
            coal: state.coalMarket,
            iron: state.ironMarket,
            presentation: .compact,
            reduceMotion: marketReduceMotion,
            onExpand: { toggleMeasuredOverlay(.resourceMarket) }
        )
            .prototypeRenderAcknowledgement(
                renderAcknowledgements.ticket(for: .marketUpdate),
                tracker: renderAcknowledgements
            )
            .padding(.leading, metrics.leftRailWidth + 8)
            .padding(.bottom, metrics.handHeight + 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func actionButton(metrics: MatchLayoutMetrics) -> some View {
        Button {
            interaction.toggleOverlay(.actionGrid)
        } label: {
            Label("行动", systemImage: "bolt.fill")
                .lineLimit(1)
                .frame(minWidth: 60, minHeight: 60)
        }
        .buttonStyle(BrassPrimaryButtonStyle())
        .frame(minWidth: 60, minHeight: 60)
        .padding(.trailing, metrics.rightRailWidth + 8)
        .padding(.bottom, metrics.handHeight + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .accessibilityLabel("打开行动选择")
        .accessibilityIdentifier("match.actionButton")
    }

    private func actionFlow(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        let selectedCardTitle = state.hand
            .first(where: { $0.id == interaction.selectedCardID })?
            .title ?? "未选择卡牌"

        return ActionFlowView(
            flow: interaction.flow,
            selectedCardTitle: selectedCardTitle,
            isRailEra: state.era == "铁路时代",
            locationNamesByID: Dictionary(
                uniqueKeysWithValues: state.locations.map { ($0.id, $0.name) }
            ),
            routeNamesByID: routeNamesByID(state: state),
            industryNamesByID: Dictionary(
                uniqueKeysWithValues: state.industries.map { ($0.id, industryName($0.kind)) }
            ),
            cardTitlesByID: Dictionary(
                uniqueKeysWithValues: state.hand.map { ($0.id, $0.title) }
            ),
            actionNumber: state.actionNumber,
            fixture: .standard,
            availableTargetIDs: highlightedIDsInFixtureOrder(state: state),
            onSelectTarget: { selectMapTarget($0, state: state) },
            onSetNetworkCount: interaction.setNetworkCount,
            onToggleSaleOption: {
                interaction.toggleSaleOption($0, fixture: .standard)
            },
            onConfirm: { submitConfirmedDraft(state: state) },
            onCancel: interaction.cancelFlow
        )
        .frame(maxWidth: 680)
        .padding(.leading, metrics.leftRailWidth + 12)
        .padding(.trailing, metrics.rightRailWidth + 12)
        .padding(.bottom, metrics.handHeight + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func selectMapTarget(_ id: String, state: DemoMatchState) {
        switch interaction.flow {
        case .build:
            interaction.selectBuildLocation(id, fixture: .standard)
        case .network:
            interaction.appendNetworkRoute(id, fixture: .standard, routes: state.routes)
        case .idle, .develop, .sell, .loan, .scout, .pass:
            break
        }
    }

    private func routeNamesByID(state: DemoMatchState) -> [String: String] {
        let names = Dictionary(uniqueKeysWithValues: state.locations.map { ($0.id, $0.name) })
        return Dictionary(uniqueKeysWithValues: state.routes.map { route in
            let start = names[route.fromLocationID] ?? route.fromLocationID
            let end = names[route.toLocationID] ?? route.toLocationID
            return (route.id, "\(start)–\(end)")
        })
    }

    private func industryName(_ kind: IndustryKind) -> String {
        switch kind {
        case .cotton: "棉纺厂"
        case .manufacturer: "制造厂"
        case .pottery: "陶器厂"
        case .coal: "煤矿"
        case .iron: "炼铁厂"
        case .brewery: "啤酒厂"
        }
    }

    private func highlightedIDsInFixtureOrder(state: DemoMatchState) -> [String] {
        let highlighted = interaction.highlightedTargetIDs(fixture: .standard, routes: state.routes)
        let fixtureOrder = ActionFixture.standard.buildLocationIDs + ActionFixture.standard.networkRouteIDs
        return fixtureOrder.filter { highlighted.contains($0) }
    }

    private func transientMapLayer(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        ZStack {
            if metrics.formFactor == .phone {
                switch interaction.overlay {
                case .playerRail:
                    PlayerDrawer(
                        players: state.players,
                        showsColorAssistSymbols: preferences.colorAssistEnabled
                    )
                        .frame(width: MatchInteractionReducer.drawerWidth(viewportWidth: metrics.viewport.width))
                        .padding(.leading, metrics.leftRailWidth)
                        .padding(.top, 52)
                        .padding(.bottom, metrics.handHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                case .industryRail:
                    IndustryDrawer(industries: state.industries)
                        .frame(width: MatchInteractionReducer.drawerWidth(viewportWidth: metrics.viewport.width))
                        .padding(.trailing, metrics.rightRailWidth)
                        .padding(.top, 52)
                        .padding(.bottom, metrics.handHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                case .resourceMarket:
                    ResourceMarketView(
                        coal: state.coalMarket,
                        iron: state.ironMarket,
                        presentation: .overlay,
                        reduceMotion: marketReduceMotion,
                        onExpand: { toggleMeasuredOverlay(.resourceMarket) }
                    )
                    .prototypeRenderAcknowledgement(
                        renderAcknowledgements.ticket(for: .marketUpdate),
                        tracker: renderAcknowledgements
                    )
                    .padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 12)
                    .padding(.top, 56)
                    .padding(.bottom, metrics.handHeight + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                default:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func actionGrid(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        if interaction.overlay == .actionGrid {
            let allowedActions = state.hand
                .first(where: { $0.id == interaction.selectedCardID })?
                .allowedActions ?? []

            ActionGridView(
                allowedActions: allowedActions,
                onSelect: { action in
                    let mutation = { interaction.selectAction(action) }
                    if ActionFlowState.start(action).usesMapTargets {
                        measureRenderedResponse(.targetGlow, mutation: mutation)
                    } else {
                        mutation()
                    }
                },
                onClose: { interaction.toggleOverlay(.actionGrid) }
            )
            .padding(.trailing, metrics.rightRailWidth + 8)
            .padding(.bottom, metrics.handHeight + 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private var effectiveReduceMotion: Bool {
        preferences.reduceMotion
    }

    private var marketReduceMotion: Bool {
        guard acceptedEvent != nil else { return effectiveReduceMotion }
        return feedbackPlan?.usesMarketNumericTransition == false
    }

    private func submitConfirmedDraft(state: DemoMatchState) {
        guard let confirmedIntent = interaction.confirmedIntent() else { return }
        cancelSubmissionAndFeedbackTasks()
        acceptedEvent = nil
        feedbackPlan = nil
        resourceMotionDestinationIDs = []
        rejection = nil
        rejectionPlan = nil
        technicalFailure = nil
        technicalFailurePlan = nil
        isRejectionFocused = false
        isTechnicalFailureFocused = false

        let submittedIntent = Self.invalidTargetLaunchArgument
            ? DemoIntent(
                action: confirmedIntent.action,
                selectedCardID: confirmedIntent.selectedCardID,
                targetIDs: ["invalid-target"]
            )
            : confirmedIntent
        let submissionSnapshot = submissionGate.begin(
            intent: confirmedIntent,
            actionNumber: state.actionNumber
        )
        isSubmitting = true

        submissionTask = Task { @MainActor in
            guard let outcome = await store.submit(intent: submittedIntent, state: state),
                  !Task.isCancelled else { return }

            let currentState = renderedState ?? store.match ?? DemoFixture.match(playerCount: playerCount)
            let eventVersion: Int? = if case .accepted(let event) = outcome {
                event.version
            } else {
                nil
            }
            guard submissionGate.shouldApply(
                snapshot: submissionSnapshot,
                currentIntent: interaction.confirmedIntent(),
                currentActionNumber: currentState.actionNumber,
                eventVersion: eventVersion
            ), submissionGate.finish(snapshot: submissionSnapshot) else {
                submissionGate.invalidate()
                isSubmitting = false
                return
            }
            isSubmitting = false

            switch outcome {
            case .accepted(let event):
                apply(event: event, to: state)
                interaction.confirmFlow()
            case .rejected(let rejectedIntent):
                rejection = rejectedIntent
                rejectionPlan = DemoRejectionFeedbackPlan.make(rejection: rejectedIntent)
                isRejectionFocused = rejectionPlan?.shouldFocus == true
            case .technicalFailure(let failure):
                technicalFailure = failure
                technicalFailurePlan = DemoTechnicalFailureFeedbackPlan.make(failure: failure)
                isTechnicalFailureFocused = technicalFailurePlan?.shouldFocus == true
            }

        }
    }

    nonisolated private static var invalidTargetLaunchArgument: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-ui-testing")
            && arguments.contains("-invalid-action-target")
    }

    private func apply(event: DemoEvent, to state: DemoMatchState) {
        let plan = DemoFeedbackPlan.make(
            event: event,
            state: state,
            reduceMotion: effectiveReduceMotion,
            hapticsEnabled: preferences.isHapticsEnabled
        )
        let nextState = DemoEventReducer.applying(event, to: state)

        measureRenderedResponse(.marketUpdate) {
            withAnimation(effectiveReduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72)) {
                renderedState = nextState
                acceptedEvent = event
                feedbackPlan = plan
            }
        }

        resourceAnimationTask?.cancel()
        resourceMotionDestinationIDs = plan.initialDestinationMotionIDs
        if effectiveReduceMotion == false, plan.resourceMotions.isEmpty == false {
            resourceAnimationTask = Task { @MainActor in
                await Task.yield()
                do {
                    try await Task.sleep(
                        for: .milliseconds(Self.resourceAnimationHoldMilliseconds)
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    resourceMotionDestinationIDs = plan.finalDestinationMotionIDs
                }
            }
        }

        playAcceptedHaptics(plan.haptics)
        UIAccessibility.post(notification: .announcement, argument: plan.announcementTitle)
    }

    private func playAcceptedHaptics(_ haptics: [DemoHaptic]) {
        hapticTask?.cancel()
        guard haptics.isEmpty == false else { return }
        hapticTask = Task { @MainActor in
            for (index, haptic) in haptics.enumerated() {
                if index > 0 {
                    do {
                        try await Task.sleep(for: .milliseconds(70))
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                switch haptic {
                case .light:
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                case .medium:
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                case .success:
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        }
    }

    private func toggleMeasuredOverlay(_ overlay: MatchOverlay) {
        measureRenderedResponse(.drawerResponse) {
            interaction.toggleOverlay(overlay)
        }
    }

    private func measureRenderedResponse(
        _ name: PrototypeSignpost.Name,
        mutation: () -> Void
    ) {
        renderAcknowledgements.begin(name)
        mutation()
    }

    private func cancelSubmissionAndFeedbackTasks() {
        submissionTask?.cancel()
        resourceAnimationTask?.cancel()
        hapticTask?.cancel()
        submissionTask = nil
        resourceAnimationTask = nil
        hapticTask = nil
        store.cancelSubmission()
        submissionGate.invalidate()
        isSubmitting = false
    }

    nonisolated private static var resourceAnimationHoldMilliseconds: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"),
              let index = arguments.firstIndex(of: "-resource-animation-hold-ms"),
              arguments.indices.contains(index + 1),
              let milliseconds = Int(arguments[index + 1]) else { return 80 }
        return max(0, milliseconds)
    }

    private func resourceName(_ kind: IndustryKind) -> String {
        switch kind {
        case .coal: "煤炭"
        case .iron: "钢铁"
        case .brewery: "啤酒"
        case .cotton: "棉花"
        case .manufacturer: "制造品"
        case .pottery: "陶器"
        }
    }

    @ViewBuilder
    private func eventFeedback(metrics: MatchLayoutMetrics) -> some View {
        if let event = acceptedEvent {
            VStack(alignment: .leading, spacing: 5) {
                Label(event.title, systemImage: "checkmark.seal.fill")
                    .font(BrassTypography.title)
                    .foregroundStyle(BrassColor.brass.color)
                    .accessibilityIdentifier("event.title")

                ForEach(Array(event.effects.enumerated()), id: \.offset) { index, effect in
                    Text(effectSummary(effect))
                        .font(.caption)
                        .foregroundStyle(BrassColor.paper.color)
                        .accessibilityIdentifier("event.effect.\(index)")
                }
            }
            .brassPanel()
            .padding(.top, 56)
            .padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(event.title)
            .accessibilityIdentifier("event.accepted")
            .transition(effectiveReduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }

        if let plan = feedbackPlan {
            ForEach(Array(plan.resourceMotions.enumerated()), id: \.element.id) { index, motion in
                let isAtDestination = resourceMotionDestinationIDs.contains(motion.id)
                let point = isAtDestination ? motion.destination : motion.source
                let baseIdentifier = effectiveReduceMotion ? "event.motion.reduced" : "event.motion.animated"

                Label(
                    "\(resourceName(motion.kind))从\(motion.sourceID)移动到\(motion.destinationID)",
                    systemImage: "shippingbox.fill"
                )
                    .font(BrassTypography.label)
                    .foregroundStyle(BrassColor.coal.color)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                    .background(BrassColor.brass.color)
                    .clipShape(Capsule())
                    .position(
                        x: point.x * metrics.viewport.width,
                        y: point.y * metrics.viewport.height
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(index == 0 ? baseIdentifier : "\(baseIdentifier).\(index)")
                    .accessibilityValue(isAtDestination ? "destination" : "source")
            }
        }
    }

    @ViewBuilder
    private func rejectionFeedback(metrics: MatchLayoutMetrics) -> some View {
        if let rejection {
            VStack(alignment: .leading, spacing: 8) {
                Label("行动未接受", systemImage: "exclamationmark.triangle.fill")
                    .font(BrassTypography.title)
                    .foregroundStyle(BrassColor.danger.color)
                Text(rejection.reason)
                    .font(BrassTypography.label)
                    .foregroundStyle(BrassColor.paper.color)
                    .accessibilityIdentifier("event.rejection.reason")
                Text(rejection.recoverySuggestion)
                    .font(.caption)
                    .foregroundStyle(BrassColor.paper.color.opacity(0.82))
                    .accessibilityIdentifier("event.rejection.recovery")
            }
            .brassPanel()
            .padding(.top, 56)
            .padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                rejectionPlan?.accessibilityLabel
                    ?? "行动未接受，\(rejection.reason)，\(rejection.recoverySuggestion)"
            )
            .accessibilityValue(
                rejectionPlan?.shouldFocus == true && rejectionPlan?.preservesDraft == true
                    ? "VoiceOver焦点，草稿已保留"
                    : ""
            )
            .accessibilityIdentifier("event.rejected")
            .accessibilityFocused($isRejectionFocused)
        }
    }

    @ViewBuilder
    private func technicalFailureFeedback(metrics: MatchLayoutMetrics) -> some View {
        if let technicalFailure {
            VStack(alignment: .leading, spacing: 8) {
                Label("提交遇到技术问题", systemImage: "wifi.exclamationmark")
                    .font(BrassTypography.title)
                    .foregroundStyle(BrassColor.danger.color)
                Text(technicalFailure.diagnostic)
                    .font(BrassTypography.label)
                    .foregroundStyle(BrassColor.paper.color)
                    .accessibilityIdentifier("event.technical.diagnostic")
                Text(technicalFailure.retrySuggestion)
                    .font(.caption)
                    .foregroundStyle(BrassColor.paper.color.opacity(0.82))
                    .accessibilityIdentifier("event.technical.retry")
            }
            .brassPanel()
            .padding(.top, 56)
            .padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                technicalFailurePlan?.accessibilityLabel
                    ?? "提交遇到技术问题，\(technicalFailure.diagnostic)，\(technicalFailure.retrySuggestion)"
            )
            .accessibilityValue(
                technicalFailurePlan?.shouldFocus == true && technicalFailurePlan?.preservesDraft == true
                    ? "VoiceOver焦点，草稿已保留"
                    : ""
            )
            .accessibilityIdentifier("event.technicalFailure")
            .accessibilityFocused($isTechnicalFailureFocused)
        }
    }

    private func effectSummary(_ effect: DemoEffect) -> String {
        switch effect {
        case .moveResource(let kind, let source, let destination):
            "\(resourceName(kind))：\(source) → \(destination)"
        case .marketChanged(let coal, let iron):
            "市场：煤 \(coal.remaining) / £\(coal.cheapestPrice)，铁 \(iron.remaining) / £\(iron.cheapestPrice)"
        case .industryFlipped:
            "产业板块已翻面"
        case .incomeChanged(let oldIncome, let newIncome):
            "收入：\(oldIncome) → \(newIncome)"
        case .actionAdvanced(let oldAction, let newAction):
            "行动：\(oldAction) → \(newAction)"
        }
    }
}

private struct PlayerDrawer: View {
    let players: [PlayerSummary]
    let showsColorAssistSymbols: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("玩家顺序与花费")
                    .font(BrassTypography.title)
                    .foregroundStyle(BrassColor.brass.color)

                ForEach(players) { player in
                    HStack(spacing: 10) {
                        Image(systemName: showsColorAssistSymbols ? player.color.symbol : "circle.fill")
                            .frame(width: 28)
                            .foregroundStyle(playerTint(player.color))
                        Text("\(player.order). \(player.name)")
                        Spacer()
                        if player.isConnected == false {
                            Label("离线", systemImage: "wifi.slash")
                                .font(BrassTypography.label)
                                .foregroundStyle(BrassColor.danger.color)
                        }
                        Text("£\(player.spent)")
                            .font(BrassTypography.number)
                    }
                    .foregroundStyle(BrassColor.paper.color)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
                    .background(player.isCurrent ? BrassColor.brass.color.opacity(0.18) : BrassColor.iron.color.opacity(0.24))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(playerLabel(player))
                    .accessibilityIdentifier("drawer.player.\(player.id)")
                }
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
        .background(BrassColor.coal.color.opacity(0.95))
        .overlay(alignment: .trailing) {
            Rectangle().fill(BrassColor.brass.color.opacity(0.65)).frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overlay.playerRail")
    }

    private func playerLabel(_ player: PlayerSummary) -> String {
        let shape = showsColorAssistSymbols ? "，\(shapeName(player.color))" : ""
        let connection = player.isConnected ? "在线" : "离线"
        return "顺序 \(player.order)，\(player.name)，\(colorName(player.color))\(shape)，已花 \(player.spent) 英镑，\(connection)"
    }

    private func playerTint(_ color: PlayerColor) -> Color {
        switch color {
        case .amber: BrassColor.brass.color
        case .crimson: BrassColor.danger.color
        case .teal: Color(red: 0.20, green: 0.67, blue: 0.67)
        case .violet: Color(red: 0.61, green: 0.45, blue: 0.78)
        }
    }

    private func colorName(_ color: PlayerColor) -> String {
        switch color {
        case .amber: "琥珀色"
        case .crimson: "深红色"
        case .teal: "青绿色"
        case .violet: "紫罗兰色"
        }
    }

    private func shapeName(_ color: PlayerColor) -> String {
        switch color {
        case .amber: "菱形标记"
        case .crimson: "三角形标记"
        case .teal: "圆形标记"
        case .violet: "方形标记"
        }
    }
}

private struct IndustryDrawer: View {
    let industries: [IndustrySummary]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("产业板块")
                    .font(BrassTypography.title)
                    .foregroundStyle(BrassColor.brass.color)

                ForEach(industries) { industry in
                    HStack(spacing: 10) {
                        Image(systemName: industry.kind.symbol)
                            .frame(width: 28)
                        Text(industry.kind.rawValue.capitalized)
                        Spacer()
                        Text("L\(industry.level) · £\(industry.cost)")
                            .font(BrassTypography.number)
                    }
                    .foregroundStyle(BrassColor.paper.color)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
                    .background(BrassColor.iron.color.opacity(industry.isAvailable ? 0.32 : 0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
        .background(BrassColor.coal.color.opacity(0.95))
        .overlay(alignment: .leading) {
            Rectangle().fill(BrassColor.brass.color.opacity(0.65)).frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overlay.industryRail")
    }
}

private struct MatchPreview: View {
    let playerCount: Int

    var body: some View {
        MatchView(playerCount: playerCount)
            .environment(DemoSessionStore())
    }
}

#Preview("Phone 667 × 375", traits: .fixedLayout(width: 667, height: 375)) {
    MatchPreview(playerCount: 2)
}

#Preview("Phone 852 × 393", traits: .fixedLayout(width: 852, height: 393)) {
    MatchPreview(playerCount: 3)
}

#Preview("Phone 932 × 430", traits: .fixedLayout(width: 932, height: 430)) {
    MatchPreview(playerCount: 4)
}

#Preview("Tablet 1024 × 768", traits: .fixedLayout(width: 1024, height: 768)) {
    MatchPreview(playerCount: 2)
}

#Preview("Tablet 1194 × 834", traits: .fixedLayout(width: 1194, height: 834)) {
    MatchPreview(playerCount: 3)
}

#Preview("Tablet 1366 × 1024", traits: .fixedLayout(width: 1366, height: 1024)) {
    MatchPreview(playerCount: 4)
}
#endif
