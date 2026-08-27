#if DEBUG
import SwiftUI

struct ActionFlowView: View {
    let flow: ActionFlowState
    let selectedCardTitle: String
    let isRailEra: Bool
    let locationNamesByID: [String: String]
    let routeNamesByID: [String: String]
    let industryNamesByID: [String: String]
    let cardTitlesByID: [String: String]
    let actionNumber: Int
    let fixture: ActionFixture
    let availableTargetIDs: [String]
    let onSelectTarget: (String) -> Void
    let onSetNetworkCount: (NetworkCount) -> Void
    let onToggleSaleOption: (String) -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @ViewBuilder
    var body: some View {
        switch flow {
        case .idle:
            EmptyView()
        case .build(let draft):
            buildFlow(draft)
        case .network(let draft):
            networkFlow(draft)
        case .develop(let draft):
            developFlow(draft)
        case .sell(let draft):
            sellFlow(draft)
        case .loan:
            panel(
                action: .loan,
                title: "贷款",
                instruction: "获得 £30，并降低收入等级",
                details: []
            )
        case .scout(let draft):
            scoutFlow(draft)
        case .pass:
            panel(
                action: .pass,
                title: "跳过行动",
                instruction: "弃掉所选牌并结束这次行动",
                details: []
            )
        }
    }

    private func panel(
        action: GameAction,
        title: String,
        instruction: String,
        details: [String],
        networkCost: NetworkActionCost? = nil,
        developIndustryCount: Int = 1,
        sellOptions: [SellOption] = [],
        previewItems: [ConfirmationPreviewItem] = []
    ) -> some View {
        let summary = ActionConfirmationSummary.fixture(
            cardTitle: selectedCardTitle,
            action: action,
            networkCost: networkCost,
            developIndustryCount: developIndustryCount,
            sellOptions: sellOptions
        )
        let resolvedPreviewItems = action == .pass
            ? ConfirmationPreviewItem.pass(summary: summary, actionNumber: actionNumber)
            : previewItems

        return ConfirmationPanel(
            title: title,
            instruction: instruction,
            details: details,
            summary: summary,
            previewItems: resolvedPreviewItems,
            incomeAccessibilityIdentifier: action == .loan
                ? "action.beforeAfter.income"
                : "action.income",
            isConfirmEnabled: flow.isConfirmable,
            onConfirm: onConfirm,
            onCancel: onCancel
        )
    }

    private func scoutFlow(_ draft: ScoutDraft) -> some View {
        let previews = draft.extraCardIDs.enumerated().map { index, id in
            let cardTitle = cardTitlesByID[id] ?? id
            return ConfirmationPreviewItem(
                title: index == 0 ? "地点万能牌 · \(cardTitle)" : "产业万能牌 · \(cardTitle)",
                symbol: index == 0 ? "map.fill" : "building.2.fill",
                identifier: "scout.wildcard.\(index)"
            )
        }

        return panel(
            action: .scout,
            title: "侦察",
            instruction: "再选择 2 张普通牌用于弃置（\(draft.extraCardIDs.count)/2）",
            details: [],
            previewItems: previews
        )
    }

    private func networkFlow(_ draft: NetworkDraft) -> some View {
        let cost = NetworkActionCost(isRailEra: isRailEra, count: draft.count)

        return VStack(spacing: 8) {
            if isRailEra {
                Picker(
                    "铁路数量",
                    selection: Binding(
                        get: { draft.count },
                        set: onSetNetworkCount
                    )
                ) {
                    Text("1 条").tag(NetworkCount.one)
                    Text("2 条").tag(NetworkCount.two)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .accessibilityIdentifier("network.count")
            } else {
                Label("运河时代固定铺设 1 条运河", systemImage: "water.waves")
                    .font(BrassTypography.label)
                    .foregroundStyle(BrassColor.paper.color)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(BrassColor.coal.color.opacity(0.86))
                    .clipShape(Capsule())
                    .accessibilityIdentifier("network.canalCount")
            }

            targetPicker()

            panel(
                action: .network,
                title: isRailEra ? "铺设铁路" : "铺设运河",
                instruction: "按顺序选择 \(draft.count.rawValue) 条高亮线路",
                details: networkDetails(draft, cost: cost),
                networkCost: cost
            )
        }
    }

    private func buildFlow(_ draft: BuildDraft) -> some View {
        VStack(spacing: 8) {
            targetPicker()
            panel(
                action: .build,
                title: "建造产业",
                instruction: "在地图或目标栏选择一个高亮地点",
                details: buildDetails(draft)
            )
        }
    }

    private func developFlow(_ draft: DevelopDraft) -> some View {
        panel(
            action: .develop,
            title: "发展产业",
            instruction: "从右侧产业栏选择 1 至 2 个板块（\(draft.industryIDs.count)/2）",
            details: draft.industryIDs.enumerated().map { index, id in
                "\(index + 1). \(industryNamesByID[id] ?? id) · 铁来源 1"
            },
            developIndustryCount: draft.industryIDs.count
        )
    }

    private func sellFlow(_ draft: SellDraft) -> some View {
        let selectedOptions = sellOptions(for: draft)

        return VStack(spacing: 8) {
            merchantOptionPicker(draft)
            panel(
                action: .sell,
                title: "出售商品",
                instruction: "从右侧产业栏选择产业，再选择商人和啤酒来源",
                details: selectedOptions.enumerated().map { index, option in
                    "\(index + 1). \(option.merchantName) · +£\(option.reward) · 收入 +\(option.incomeIncrease)"
                },
                sellOptions: selectedOptions
            )
        }
    }

    @ViewBuilder
    private func merchantOptionPicker(_ draft: SellDraft) -> some View {
        if let industryID = draft.focusedIndustryID {
            let options = fixture.sellOptions.filter { $0.industryID == industryID }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(options) { option in
                        let isSelected = draft.optionIDs.contains(option.id)
                        Button {
                            onToggleSaleOption(option.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "building.columns.fill")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(option.merchantName) · +£\(option.reward)")
                                        .font(BrassTypography.label)
                                    Text("啤酒：\(option.beerSource) · 收入 +\(option.incomeIncrease)")
                                        .font(.caption2)
                                }
                            }
                            .foregroundStyle(BrassColor.paper.color)
                            .padding(.horizontal, 12)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(
                                isSelected
                                    ? BrassColor.brass.color.opacity(0.30)
                                    : BrassColor.coal.color.opacity(0.90)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(BrassColor.brass.color.opacity(0.72), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(option.merchantName)，奖励 \(option.reward) 英镑，啤酒来源 \(option.beerSource)，收入增加 \(option.incomeIncrease)"
                        )
                        .accessibilityIdentifier("sell.option.\(option.id)")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: 560)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sell.merchantCard.\(industryID)")
        } else {
            Label("从右侧选择可出售产业", systemImage: "arrow.right.circle")
                .font(BrassTypography.label)
                .foregroundStyle(BrassColor.paper.color)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(BrassColor.coal.color.opacity(0.90))
                .clipShape(Capsule())
                .accessibilityIdentifier("sell.chooseIndustry")
        }
    }

    private func sellOptions(for draft: SellDraft) -> [SellOption] {
        draft.optionIDs.compactMap { id in
            fixture.sellOptions.first(where: { $0.id == id })
        }
    }

    @ViewBuilder
    private func targetPicker() -> some View {
        if availableTargetIDs.isEmpty == false {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(availableTargetIDs, id: \.self) { id in
                        Button {
                            onSelectTarget(id)
                        } label: {
                            Label(targetName(id), systemImage: "scope")
                                .font(BrassTypography.label)
                                .foregroundStyle(BrassColor.paper.color)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background(BrassColor.coal.color.opacity(0.9))
                                .clipShape(Capsule())
                                .overlay {
                                    Capsule().stroke(BrassColor.brass.color.opacity(0.72), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("选择目标，\(targetName(id))")
                        .accessibilityIdentifier("flow.target.\(id)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: 560)
        }
    }

    private func targetName(_ id: String) -> String {
        locationNamesByID[id] ?? routeNamesByID[id] ?? id
    }

    private func buildDetails(_ draft: BuildDraft) -> [String] {
        let location = draft.locationID.flatMap { locationNamesByID[$0] } ?? "尚未选择地点"
        return [
            "地点：\(location)",
            "产业成本：£5",
            "煤来源：相连煤矿或市场",
            "铁来源：任意铁厂或市场"
        ]
    }

    private func networkDetails(_ draft: NetworkDraft, cost: NetworkActionCost) -> [String] {
        var details = draft.routeIDs.enumerated().map { index, id in
            "\(index + 1). \(routeNamesByID[id] ?? id)"
        }
        if details.isEmpty {
            details.append("尚未选择线路")
        }
        details.append(cost.detailText)
        return details
    }
}
#endif
