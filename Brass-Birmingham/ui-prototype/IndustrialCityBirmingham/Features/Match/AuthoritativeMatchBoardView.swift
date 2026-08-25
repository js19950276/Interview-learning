import SwiftUI

struct AuthoritativeMatchBoardView: View {
    @Bindable var store: SessionViewStore
    @State private var interaction = MatchInteractionReducer()
    @State private var selections: [GameCore.LegalChoiceValue] = []
    @State private var selectionLabels: [String] = []
    @State private var forcedSaleIDs: [String] = []

    var body: some View {
        GeometryReader { proxy in
            let metrics = MatchLayoutMetrics(viewport: proxy.size)
            if let snapshot = store.snapshot, let catalog = store.presentationCatalog {
                switch Result(catching: {
                    try RealMatchViewModel.make(
                        snapshot: snapshot, hostPlayerID: store.hostPlayerID, catalog: catalog
                    )
                }) {
                case .success(let state):
                    ZStack {
                    GameMapView(
                        state: state,
                        highlightedIDs: highlightedIDs,
                        onTargetTap: selectMapTarget,
                        onBackgroundTap: interaction.dismissOverlay,
                        legendInsets: MapLegendInsets(top: 0, trailing: metrics.rightRailWidth)
                    )
                    .padding(.top, metrics.mapTopInset)
                    .background(BrassColor.coal.color)
                    .ignoresSafeArea(edges: [.horizontal, .bottom])

                    leftRail(state: state, metrics: metrics)
                    rightRail(state: state, metrics: metrics)
                    header(state: state, metrics: metrics)
                    hand(state: state, metrics: metrics)
                    if metrics.marketPlacement == .bottomLeftCompact {
                        compactMarket(state: state, metrics: metrics)
                    }
                    actions(state: state, metrics: metrics)
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
                            .padding(.top, 56)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .accessibilityIdentifier("real.recovery.advance")
                    }
#endif
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
            PlayerRailView(players: state.players, metrics: metrics)
            if metrics.marketPlacement == .underPlayerRail {
                ResourceMarketView(
                    coal: state.coalMarket, iron: state.ironMarket,
                    presentation: .full, reduceMotion: true
                )
            }
        }
        .frame(width: metrics.leftRailWidth)
        .padding(.top, 52).padding(.bottom, metrics.handHeight + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func rightRail(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        IndustryRailView(industries: state.industries, metrics: metrics, reduceMotion: true)
            .padding(.top, 52).padding(.bottom, metrics.handHeight + 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private func header(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("房间 \(store.roomID.rawValue)")
                    .accessibilityIdentifier("real.room")
                Text("当前：\(store.snapshot?.activePlayerID.rawValue ?? "-")")
                    .accessibilityIdentifier("real.turn")
                Spacer(minLength: 4)
                Text("v\(store.version.rawValue) · \(store.syncStatus.rawValue)")
                    .accessibilityIdentifier("real.sync")
            }
            .font(.caption2.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(BrassColor.paper.color)
            .padding(.horizontal, 8)

            MatchHeaderView(state: state)
        }
        .padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 8)
        .padding(.top, 4)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func hand(state: DemoMatchState, metrics: MatchLayoutMetrics) -> some View {
        HandView(
            cards: state.hand, formFactor: metrics.formFactor,
            selectedCardID: interaction.selectedCardID,
            scoutCardIDs: [], selectedScoutCardIDs: [],
            onSelect: { id in
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
            if interaction.selectedCardID != nil {
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
            .padding(.bottom, metrics.handHeight + 8)
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
                onCancel: {
                    interaction.cancelFlow(); selections = []; selectionLabels = []; store.cancelLegalFlow()
                }
            )
            .padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 12)
            .padding(.bottom, metrics.handHeight + 8)
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
        Set(store.legalResponse?.nextChoices.compactMap { choice in
            switch choice.value {
            case .buildTarget(let locationID, _): locationID
            case .route(let id): id
            default: nil
            }
        } ?? [])
    }

    private func selectMapTarget(_ id: String) {
        guard let choice = store.legalResponse?.nextChoices.first(where: {
            switch $0.value {
            case .buildTarget(let locationID, _): locationID == id
            case .route(let routeID): routeID == id
            default: false
            }
        }) else { return }
        select(choice)
    }

    private func select(_ choice: GameCore.LegalChoice) {
        selections.append(choice.value)
        selectionLabels.append(choice.label)
        guard let action = interaction.selectedAction,
              let kind = GameCore.ActionKind(rawValue: action.rawValue) else { return }
        Task { await store.requestLegalOptions(action: kind, selections: selections) }
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
