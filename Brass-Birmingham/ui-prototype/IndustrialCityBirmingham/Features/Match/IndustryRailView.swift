import SwiftUI

struct IndustryRailView: View {
    let industries: [IndustrySummary]
    let metrics: MatchLayoutMetrics
    let selectableIndustryIDs: Set<String>
    let selectedIndustryIDs: Set<String>
    let selectionCountText: String?
    let flippedIndustryIDs: Set<String>
    let reduceMotion: Bool
    let onSelectIndustry: ((String) -> Void)?
    let accessibilityEnabled: Bool

    init(
        industries: [IndustrySummary],
        metrics: MatchLayoutMetrics,
        selectableIndustryIDs: Set<String> = [],
        selectedIndustryIDs: Set<String> = [],
        selectionCountText: String? = nil,
        flippedIndustryIDs: Set<String> = [],
        reduceMotion: Bool = false,
        onSelectIndustry: ((String) -> Void)? = nil,
        accessibilityEnabled: Bool = true
    ) {
        self.industries = industries
        self.metrics = metrics
        self.selectableIndustryIDs = selectableIndustryIDs
        self.selectedIndustryIDs = selectedIndustryIDs
        self.selectionCountText = selectionCountText
        self.flippedIndustryIDs = flippedIndustryIDs
        self.reduceMotion = reduceMotion
        self.onSelectIndustry = onSelectIndustry
        self.accessibilityEnabled = accessibilityEnabled
    }

    var body: some View {
        railContent
        .padding(.vertical, metrics.formFactor == .tablet ? 10 : 4)
        .padding(.horizontal, metrics.formFactor == .tablet ? 8 : 0)
        .frame(width: metrics.rightRailWidth)
        .modifier(IndustrialPanelSurface(axis: .vertical))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(BrassColor.brass.color.opacity(0.45))
                .frame(width: 1)
        }
        .overlay(alignment: .topLeading) {
            if accessibilityEnabled {
                ZStack {
                    accessibilityMarker(
                        label: "产业栏内容",
                        identifier: "match.industryRail.content"
                    )
                    ForEach(industries) { industry in
                        accessibilityMarker(
                            label: "\(industryName(industry.kind))徽章",
                            identifier: "industry.medallion.industry-\(industry.kind.rawValue)"
                        )
                    }
                }
                .accessibilityElement(children: .contain)
                .allowsHitTesting(false)
            }
        }
    }

    private var railContent: some View {
        VStack(spacing: metrics.formFactor == .tablet ? 8 : 4) {
            if metrics.formFactor == .tablet {
                HStack {
                    Text("产业板块")
                    Spacer()
                    selectionCount
                }
                .font(BrassTypography.label)
                .foregroundStyle(BrassColor.brass.color)
            } else if selectionCountText != nil {
                selectionCount
            }

            if metrics.formFactor == .tablet {
                ForEach(industries) { industry in
                    industryRow(industry)
                }
            } else {
                // 手机端竖条高度有限:瓦片用紧凑定高布局并允许条内滚动,
                // 保证任意屏高下内容都不会互相压叠。
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(industries) { industry in
                            industryRow(industry)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    @ViewBuilder
    private func industryRow(_ industry: IndustrySummary) -> some View {
        if selectableIndustryIDs.contains(industry.id), let onSelectIndustry {
            Button {
                onSelectIndustry(industry.id)
            } label: {
                industryContent(industry)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("选择产业，\(industryAccessibilityLabel(industry))")
            .accessibilityIdentifier(accessibilityEnabled ? "industry.select.\(industry.id)" : "")
            .accessibilityAddTraits(selectedIndustryIDs.contains(industry.id) ? .isSelected : [])
            .accessibilityHidden(!accessibilityEnabled)
        } else {
            industryContent(industry)
        }
    }

    @ViewBuilder
    private var selectionCount: some View {
        if let selectionCountText {
            Text(selectionCountText)
                .font(BrassTypography.number)
                .foregroundStyle(BrassColor.brass.color)
                .accessibilityIdentifier("develop.selectionCount")
        }
    }

    @ViewBuilder
    private func industryContent(_ industry: IndustrySummary) -> some View {
        Group {
            if metrics.formFactor == .tablet {
                tabletIndustry(industry)
            } else {
                phoneIndustry(industry)
            }
        }
        .rotation3DEffect(
            .degrees(flippedIndustryIDs.contains(industry.id) && reduceMotion == false ? 180 : 0),
            axis: (x: 0, y: 1, z: 0)
        )
        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.72), value: flippedIndustryIDs)
        .modifier(IndustryTileChrome(style: chromeStyle(for: industry)))
        .accessibilityIdentifier(accessibilityEnabled ? "industry.flip.\(industry.id)" : "")
        .accessibilityValue(flippedIndustryIDs.contains(industry.id) ? "已翻面" : "未翻面")
        .accessibilityHidden(!accessibilityEnabled)
    }

    private func chromeStyle(for industry: IndustrySummary) -> IndustryRailChromeStyle {
        IndustryRailChromeStyle.style(
            for: industry,
            selectableIndustryIDs: selectableIndustryIDs,
            selectedIndustryIDs: selectedIndustryIDs
        )
    }

    private func tabletIndustry(_ industry: IndustrySummary) -> some View {
        HStack(spacing: 7) {
            industryMedallion(industry, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(industryName(industry.kind))
                        .font(BrassTypography.label)
                    Spacer()
                    Text("L\(industry.level) · £\(industry.cost)")
                        .font(BrassTypography.number)
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    if let remain = industry.remainingTotal {
                        resource("剩", value: remain, icon: "square.stack.fill")
                    }
                    resource("煤", value: industry.coalCost, icon: "seal.fill")
                    resource("铁", value: industry.ironCost, icon: "cube.fill")
                    resource("VP", value: industry.victoryPoints ?? 0, icon: "shield.fill")
                    resource("路", value: industry.linkPoints ?? 0, icon: "arrow.triangle.turn.up.right.diamond.fill")
                    Spacer()
                    Label(industry.isAvailable ? "可用" : "已用", systemImage: industry.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption2)
                }
            }
        }
        .foregroundStyle(BrassColor.paper.color)
        .padding(7)
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(industryAccessibilityLabel(industry))
    }

    private func phoneIndustry(_ industry: IndustrySummary) -> some View {
        // 垫板式紧凑卡:左列费用+材料,中间徽章,右列 VP/路分(参照实体玩家垫板)。
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                costCoin(industry.cost)
                Spacer(minLength: 2)
                industryMedallion(industry, size: 22)
                Spacer(minLength: 2)
                statBadge("VP", industry.victoryPoints, tint: BrassColor.paper.color)
            }
            HStack(spacing: 3) {
                materialChip("煤", industry.coalCost, icon: "seal.fill")
                materialChip("铁", industry.ironCost, icon: "cube.fill")
                Spacer(minLength: 2)
                statBadge("路", industry.linkPoints, tint: BrassColor.brass.color)
            }
        }
        .padding(.horizontal, 2)
        .frame(
            maxWidth: .infinity,
            minHeight: selectableIndustryIDs.contains(industry.id) ? 54 : 46,
            maxHeight: selectableIndustryIDs.contains(industry.id) ? 54 : 46
        )
        .foregroundStyle(BrassColor.paper.color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(industryAccessibilityLabel(industry) + industrialValueLabel(industry))
    }

    /// 建造费用:黄铜圆底钱币数字。
    private func costCoin(_ cost: Int) -> some View {
        Text("\(cost)")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(BrassColor.coal.color)
            .frame(width: 14, height: 14)
            .background(Circle().fill(BrassColor.brass.color))
            .overlay(Circle().stroke(BrassColor.paper.color.opacity(0.4), lineWidth: 0.5))
    }

    /// 材料(煤/铁)用量:图标 + 数字,无需求时置灰显示 0。
    private func materialChip(_ name: String, _ value: Int, icon: String) -> some View {
        HStack(spacing: 1) {
            Image(systemName: icon)
                .font(.system(size: 7))
            Text("\(value)")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(value > 0 ? BrassColor.paper.color : BrassColor.paper.color.opacity(0.4))
    }

    /// VP/路分徽章:数值加标签缩写。
    private func statBadge(_ label: String, _ value: Int?, tint: Color) -> some View {
        HStack(spacing: 1) {
            Text(label)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(tint.opacity(0.7))
            Text("\(value ?? 0)")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }

    private func industrialValueLabel(_ industry: IndustrySummary) -> String {
        "，结算 \(industry.victoryPoints ?? 0) 分，路分 \(industry.linkPoints ?? 0)"
    }

    private func industryMedallion(_ industry: IndustrySummary, size: CGFloat) -> some View {
        Image(IndustrialMatchAsset.industryMedallion(industry.kind).name)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
            .opacity(industry.isAvailable ? 1 : 0.46)
            .accessibilityHidden(true)
    }

    private func accessibilityMarker(label: String, identifier: String) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }

    private func resource(_ title: String, value: Int, icon: String) -> some View {
        Label("\(title) \(value)", systemImage: icon)
            .font(.caption2.monospacedDigit())
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

    private func industryAccessibilityLabel(_ industry: IndustrySummary) -> String {
        "\(industryName(industry.kind))，等级 \(industry.level)，费用 \(industry.cost) 英镑，煤炭 \(industry.coalCost)，钢铁 \(industry.ironCost)，\(industry.isAvailable ? "可用" : "不可用")"
    }
}

nonisolated enum IndustryRailChromeStyle: Equatable, Sendable {
    case selected
    case selectable
    case available
    case unavailable

    static func style(
        for industry: IndustrySummary,
        selectableIndustryIDs: Set<String>,
        selectedIndustryIDs: Set<String>
    ) -> Self {
        if selectedIndustryIDs.contains(industry.id) { return .selected }
        if selectableIndustryIDs.contains(industry.id), industry.isAvailable { return .selectable }
        if industry.isAvailable { return .available }
        return .unavailable
    }
}

private struct IndustryTileChrome: ViewModifier {
    let style: IndustryRailChromeStyle

    func body(content: Content) -> some View {
        content
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(borderColor, lineWidth: borderWidth)
            }
            .shadow(color: glowColor, radius: glowRadius)
    }

    private var backgroundColor: Color {
        switch style {
        case .selected:
            BrassColor.brass.color.opacity(0.30)
        case .selectable:
            BrassColor.legalGreen.color.opacity(0.16)
        case .available:
            BrassColor.forgedIron.color.opacity(0.34)
        case .unavailable:
            BrassColor.forgedIron.color.opacity(0.18)
        }
    }

    private var borderColor: Color {
        switch style {
        case .selected:
            BrassColor.brass.color.opacity(0.88)
        case .selectable:
            BrassColor.legalGreen.color.opacity(0.78)
        case .available:
            BrassColor.fog.color.opacity(0.24)
        case .unavailable:
            BrassColor.unavailableRed.color.opacity(0.58)
        }
    }

    private var borderWidth: CGFloat {
        switch style {
        case .selected: 2
        case .selectable, .available, .unavailable: 1
        }
    }

    private var glowColor: Color {
        switch style {
        case .selected:
            BrassColor.brass.color.opacity(0.34)
        case .selectable:
            BrassColor.legalGreen.color.opacity(0.38)
        case .available, .unavailable:
            Color.clear
        }
    }

    private var glowRadius: CGFloat {
        switch style {
        case .selected: 7
        case .selectable: 6
        case .available, .unavailable: 0
        }
    }
}
