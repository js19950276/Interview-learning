import SwiftUI

struct NetworkActionCost: Equatable {
    let money: Int
    let coal: Int
    let beer: Int

    init(isRailEra: Bool, count: NetworkCount) {
        if isRailEra == false {
            money = 3
            coal = 0
            beer = 0
        } else if count == .one {
            money = 5
            coal = 1
            beer = 0
        } else {
            money = 15
            coal = 2
            beer = 1
        }
    }

    var detailText: String {
        var components = ["费用：£\(money)"]
        if coal > 0 { components.append("\(coal) 煤") }
        if beer > 0 { components.append("\(beer) 啤酒") }
        return components.joined(separator: " + ")
    }
}

struct ActionConfirmationSummary: Equatable {
    let discardedCard: String
    let moneyDelta: Int
    let coalDelta: Int
    let ironDelta: Int
    let beerDelta: Int
    let incomeBefore: Int?
    let incomeAfter: Int?
    let moneyBefore: Int?
    let moneyAfter: Int?
    let discardedCardCount: Int
    let actionAdvance: Int

    init(
        discardedCard: String,
        moneyDelta: Int,
        coalDelta: Int,
        ironDelta: Int,
        beerDelta: Int,
        incomeBefore: Int?,
        incomeAfter: Int?,
        moneyBefore: Int? = nil,
        moneyAfter: Int? = nil,
        discardedCardCount: Int = 1,
        actionAdvance: Int = 0
    ) {
        self.discardedCard = discardedCard
        self.moneyDelta = moneyDelta
        self.coalDelta = coalDelta
        self.ironDelta = ironDelta
        self.beerDelta = beerDelta
        self.incomeBefore = incomeBefore
        self.incomeAfter = incomeAfter
        self.moneyBefore = moneyBefore
        self.moneyAfter = moneyAfter
        self.discardedCardCount = discardedCardCount
        self.actionAdvance = actionAdvance
    }

    static func fixture(
        cardTitle: String,
        action: GameAction,
        networkCost: NetworkActionCost? = nil,
        developIndustryCount: Int = 1,
        sellOptions: [SellOption] = []
    ) -> ActionConfirmationSummary {
        precondition(action != .network || networkCost != nil, "Network actions require an era-aware cost")

        return switch action {
        case .build:
            ActionConfirmationSummary(
                discardedCard: cardTitle,
                moneyDelta: -5,
                coalDelta: -1,
                ironDelta: 0,
                beerDelta: 0,
                incomeBefore: nil,
                incomeAfter: nil
            )
        case .network:
            ActionConfirmationSummary(
                discardedCard: cardTitle,
                moneyDelta: -networkCost!.money,
                coalDelta: -networkCost!.coal,
                ironDelta: 0,
                beerDelta: -networkCost!.beer,
                incomeBefore: nil,
                incomeAfter: nil
            )
        case .develop:
            ActionConfirmationSummary(
                discardedCard: cardTitle,
                moneyDelta: -3,
                coalDelta: 0,
                ironDelta: -developIndustryCount,
                beerDelta: 0,
                incomeBefore: nil,
                incomeAfter: nil
            )
        case .sell:
            ActionConfirmationSummary(
                discardedCard: cardTitle,
                moneyDelta: sellOptions.reduce(0) { $0 + $1.reward },
                coalDelta: 0,
                ironDelta: 0,
                beerDelta: -sellOptions.count,
                incomeBefore: 5,
                incomeAfter: 5 + sellOptions.reduce(0) { $0 + $1.incomeIncrease }
            )
        case .loan:
            ActionConfirmationSummary(
                discardedCard: cardTitle,
                moneyDelta: 30,
                coalDelta: 0,
                ironDelta: 0,
                beerDelta: 0,
                incomeBefore: 5,
                incomeAfter: 2,
                moneyBefore: 17,
                moneyAfter: 47
            )
        case .scout:
            ActionConfirmationSummary(
                discardedCard: cardTitle,
                moneyDelta: 0,
                coalDelta: 0,
                ironDelta: 0,
                beerDelta: 0,
                incomeBefore: nil,
                incomeAfter: nil
            )
        case .pass:
            ActionConfirmationSummary(
                discardedCard: cardTitle,
                moneyDelta: 0,
                coalDelta: 0,
                ironDelta: 0,
                beerDelta: 0,
                incomeBefore: nil,
                incomeAfter: nil,
                actionAdvance: 1
            )
        }
    }
}

struct ConfirmationPreviewItem: Equatable, Identifiable {
    let title: String
    let symbol: String
    let identifier: String

    var id: String { identifier }

    static func pass(
        summary: ActionConfirmationSummary,
        actionNumber: Int
    ) -> [ConfirmationPreviewItem] {
        [
            ConfirmationPreviewItem(
                title: "弃掉 \(summary.discardedCardCount) 张所选卡牌",
                symbol: "rectangle.portrait.fill",
                identifier: "pass.discard"
            ),
            ConfirmationPreviewItem(
                title: "行动计数从 \(actionNumber) 变为 \(actionNumber + summary.actionAdvance)",
                symbol: "arrow.right.circle.fill",
                identifier: "pass.actionAdvance"
            )
        ]
    }
}

struct ConfirmationPanel: View {
    let title: String
    let instruction: String
    let details: [String]
    let summary: ActionConfirmationSummary
    let previewItems: [ConfirmationPreviewItem]
    let incomeAccessibilityIdentifier: String
    let isConfirmEnabled: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(BrassTypography.title)
                        .foregroundStyle(BrassColor.brass.color)
                    Text(instruction)
                        .font(BrassTypography.label)
                        .foregroundStyle(BrassColor.paper.color.opacity(0.78))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Label(summary.discardedCard, systemImage: "rectangle.portrait.on.rectangle.portrait")
                    .font(BrassTypography.label)
                    .foregroundStyle(BrassColor.paper.color)
                    .lineLimit(1)
                    .accessibilityLabel("弃掉的卡牌，\(summary.discardedCard)")
            }

            if details.isEmpty == false {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(details.enumerated()), id: \.offset) { index, detail in
                            Text(detail)
                                .font(BrassTypography.label)
                                .foregroundStyle(BrassColor.paper.color)
                                .padding(.horizontal, 9)
                                .frame(minHeight: 28)
                                .background(BrassColor.iron.color.opacity(0.52))
                                .clipShape(Capsule())
                                .accessibilityIdentifier("action.detail.\(index)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if previewItems.isEmpty == false {
                HStack(spacing: 8) {
                    ForEach(previewItems) { item in
                        Label(item.title, systemImage: item.symbol)
                            .font(BrassTypography.label)
                            .foregroundStyle(BrassColor.paper.color)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .background(BrassColor.iron.color.opacity(0.72))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(BrassColor.brass.color.opacity(0.72), lineWidth: 1)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(item.title)
                            .accessibilityIdentifier(item.identifier)
                    }
                }
            }

            HStack(spacing: 8) {
                if let before = summary.moneyBefore, let after = summary.moneyAfter {
                    beforeAfterItem(
                        "金钱",
                        identifier: "action.beforeAfter.money",
                        symbol: "sterlingsign.circle.fill",
                        before: before,
                        after: after
                    )
                } else {
                    deltaItem("金钱", identifier: "money", symbol: "sterlingsign.circle.fill", value: summary.moneyDelta)
                    deltaItem("煤", identifier: "coal", symbol: "flame.fill", value: summary.coalDelta)
                    deltaItem("铁", identifier: "iron", symbol: "cube.fill", value: summary.ironDelta)
                    deltaItem("啤酒", identifier: "beer", symbol: "mug.fill", value: summary.beerDelta)
                }

                if let before = summary.incomeBefore, let after = summary.incomeAfter {
                    beforeAfterItem(
                        "收入",
                        identifier: incomeAccessibilityIdentifier,
                        symbol: "chart.line.uptrend.xyaxis",
                        before: before,
                        after: after
                    )
                }

                Spacer(minLength: 4)

                Button("取消", action: onCancel)
                    .font(BrassTypography.label)
                    .foregroundStyle(BrassColor.paper.color)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 45)
                    .background(BrassColor.iron.color.opacity(0.72))
                    .clipShape(Capsule())
                    .accessibilityIdentifier("action.cancel")

                Button("确认", action: onConfirm)
                    .buttonStyle(BrassPrimaryButtonStyle())
                    .disabled(!isConfirmEnabled)
                    .opacity(isConfirmEnabled ? 1 : 0.45)
                    .accessibilityIdentifier("action.confirm")
            }
        }
        .padding(BrassSpacing.large)
        .background {
            ZStack {
                BrassColor.darkWood.color.opacity(0.98)
                Image(IndustrialMatchAsset.woodFill.name)
                    .resizable(
                        capInsets: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12),
                        resizingMode: .tile
                    )
                    .opacity(0.24)
                    .blendMode(.softLight)
            }
            .allowsHitTesting(false)
        }
        .overlay {
            VStack(spacing: 0) {
                panelEdge
                Spacer(minLength: 0)
                panelEdge
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: BrassRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BrassRadius.panel, style: .continuous)
                .stroke(BrassColor.brass.color.opacity(0.72), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(
            color: BrassShadow.panel.color,
            radius: BrassShadow.panel.radius,
            y: BrassShadow.panel.y
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("action.confirmation")
    }

    private var panelEdge: some View {
        Image(IndustrialMatchAsset.ironHorizontal.name)
            .resizable(
                capInsets: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12),
                resizingMode: .tile
            )
            .frame(height: 8)
            .clipped()
            .opacity(0.82)
    }

    private func beforeAfterItem(
        _ label: String,
        identifier: String,
        symbol: String,
        before: Int,
        after: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: symbol)
                .font(BrassTypography.label)
            Text("\(before) → \(after)")
                .font(BrassTypography.number)
        }
        .foregroundStyle(BrassColor.paper.color)
        .frame(minWidth: 76, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)从 \(before) 变为 \(after)")
        .accessibilityIdentifier(identifier)
    }

    private func deltaItem(
        _ label: String,
        identifier: String,
        symbol: String,
        value: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: symbol)
                .font(BrassTypography.label)
            Text(deltaText(value))
                .font(BrassTypography.number)
        }
        .foregroundStyle(value < 0 ? BrassColor.danger.color : BrassColor.paper.color)
        .frame(minWidth: 46, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)变化 \(deltaText(value))")
        .accessibilityIdentifier("action.delta.\(identifier)")
    }

    private func deltaText(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}
