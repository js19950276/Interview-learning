import SwiftUI

/// 右侧产业栏的宽度预算。每一行都落在栏宽里，避免费用、徽章和分数互相盖住。
nonisolated enum IndustryRailLayout {
    struct Row: Equatable, Sendable {
        var itemWidths: [CGFloat]
        var spacing: CGFloat
        var horizontalPadding: CGFloat

        var minimumWidth: CGFloat {
            let items = itemWidths.reduce(0, +)
            let gaps = spacing * CGFloat(max(0, itemWidths.count - 1))
            return items + gaps + horizontalPadding * 2
        }
    }

    static let ironEdgeInset = MatchLayoutMetrics.panelEdgeInset

    static let phoneMedallion: CGFloat = 18
    static let phoneLevelWidth: CGFloat = 15
    static let phoneCoin: CGFloat = 14
    static let phoneInlineSpacing: CGFloat = 3
    static let phoneChipWidth: CGFloat = 17
    static let phoneChipSpacing: CGFloat = 4
    static let phoneScoreWidth: CGFloat = 18
    static let phoneScoreSpacing: CGFloat = 2

    static let phoneRows: [Row] = [
        Row(itemWidths: [phoneMedallion], spacing: 0, horizontalPadding: 0),
        Row(itemWidths: [phoneLevelWidth, phoneCoin], spacing: phoneInlineSpacing, horizontalPadding: 0),
        Row(itemWidths: [phoneChipWidth, phoneChipWidth], spacing: phoneChipSpacing, horizontalPadding: 0),
        Row(itemWidths: [phoneScoreWidth, phoneScoreWidth], spacing: phoneScoreSpacing, horizontalPadding: 0)
    ]

    static let tabletCardPadding: CGFloat = 6
    static let tabletMedallion: CGFloat = 26
    static let tabletColumnSpacing: CGFloat = 6
    static let tabletNameWidth: CGFloat = 42
    static let tabletLevelWidth: CGFloat = 20
    static let tabletCostWidth: CGFloat = 28
    static let tabletStatusWidth: CGFloat = 12
    static let tabletTitleSpacing: CGFloat = 4
    static let tabletRemainWidth: CGFloat = 44
    static let tabletChipWidth: CGFloat = 28
    static let tabletChipSpacing: CGFloat = 4
    static let tabletScoreWidth: CGFloat = 34
    static let tabletLinkWidth: CGFloat = 30
    static let tabletAvailabilityWidth: CGFloat = 32

    static let tabletRows: [Row] = [
        Row(
            itemWidths: [tabletNameWidth, tabletLevelWidth, tabletCostWidth, tabletStatusWidth],
            spacing: tabletTitleSpacing,
            horizontalPadding: 0
        ),
        Row(
            itemWidths: [tabletRemainWidth, tabletChipWidth, tabletChipWidth],
            spacing: tabletChipSpacing,
            horizontalPadding: 0
        ),
        Row(
            itemWidths: [tabletScoreWidth, tabletLinkWidth, tabletAvailabilityWidth],
            spacing: tabletChipSpacing,
            horizontalPadding: 0
        )
    ]

    static func phoneClearWidth(railWidth: CGFloat) -> CGFloat {
        railWidth - ironEdgeInset * 2
    }

    static func tabletTextColumn(railWidth: CGFloat) -> CGFloat {
        phoneClearWidth(railWidth: railWidth) - tabletCardPadding * 2 - tabletMedallion - tabletColumnSpacing
    }

    static func phoneRowsFit(railWidth: CGFloat) -> Bool {
        let clear = phoneClearWidth(railWidth: railWidth)
        return clear > 0 && phoneRows.allSatisfy { $0.minimumWidth <= clear }
    }

    static func tabletRowsFit(railWidth: CGFloat) -> Bool {
        let column = tabletTextColumn(railWidth: railWidth)
        return column > 0 && tabletRows.allSatisfy { $0.minimumWidth <= column }
    }
}

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
        .padding(.horizontal, IndustryRailLayout.ironEdgeInset)
        .frame(width: metrics.rightRailWidth)
        .modifier(IndustrialPanelSurface())
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
        .clipped()
    }

    private var railContent: some View {
        VStack(spacing: metrics.formFactor == .tablet ? 8 : 4) {
            if metrics.formFactor == .tablet {
                HStack(spacing: 4) {
                    Text("产业板块")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    selectionCount
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BrassColor.brass.color)
            } else if selectionCountText != nil {
                selectionCount
            }

            // 瓦片按栏宽排成固定列，条内滚动，避免费用、徽章和分数互相盖住。
            ScrollView(showsIndicators: false) {
                VStack(spacing: metrics.formFactor == .tablet ? 8 : 4) {
                    ForEach(industries) { industry in
                        industryRow(industry)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
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
            .frame(maxWidth: .infinity, minHeight: 44)
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
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
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
        HStack(alignment: .center, spacing: IndustryRailLayout.tabletColumnSpacing) {
            industryMedallion(industry, size: IndustryRailLayout.tabletMedallion)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: IndustryRailLayout.tabletTitleSpacing) {
                    Text(industryName(industry.kind))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: IndustryRailLayout.tabletNameWidth, alignment: .leading)
                    Text("L\(industry.level)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: IndustryRailLayout.tabletLevelWidth, alignment: .trailing)
                    Text("£\(industry.cost)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: IndustryRailLayout.tabletCostWidth, alignment: .trailing)
                    Image(systemName: industry.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(industry.isAvailable ? BrassColor.legalGreen.color : BrassColor.unavailableRed.color)
                        .frame(width: IndustryRailLayout.tabletStatusWidth)
                }
                HStack(spacing: IndustryRailLayout.tabletChipSpacing) {
                    if let remain = industry.remainingTotal {
                        tabletChip(
                            title: "剩",
                            value: remain,
                            icon: "square.stack.fill",
                            width: IndustryRailLayout.tabletRemainWidth
                        )
                    }
                    tabletChip(title: nil, value: industry.coalCost, icon: "seal.fill", width: IndustryRailLayout.tabletChipWidth)
                    tabletChip(title: nil, value: industry.ironCost, icon: "cube.fill", width: IndustryRailLayout.tabletChipWidth)
                }
                HStack(spacing: IndustryRailLayout.tabletChipSpacing) {
                    tabletChip(title: "VP", value: industry.victoryPoints ?? 0, icon: nil, width: IndustryRailLayout.tabletScoreWidth)
                    tabletChip(title: "路", value: industry.linkPoints ?? 0, icon: nil, width: IndustryRailLayout.tabletLinkWidth)
                    Text(industry.isAvailable ? "可用" : "已用")
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .frame(width: IndustryRailLayout.tabletAvailabilityWidth, alignment: .leading)
                }
            }
        }
        .foregroundStyle(BrassColor.paper.color)
        .padding(IndustryRailLayout.tabletCardPadding)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(industryAccessibilityLabel(industry))
    }

    private func phoneIndustry(_ industry: IndustrySummary) -> some View {
        // 四行各自不超出栏宽，避免费用和分数叠在徽章上。
        VStack(spacing: 1) {
            industryMedallion(industry, size: IndustryRailLayout.phoneMedallion)
            HStack(spacing: IndustryRailLayout.phoneInlineSpacing) {
                Text("L\(industry.level)")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: IndustryRailLayout.phoneLevelWidth)
                costCoin(industry.cost)
            }
            HStack(spacing: IndustryRailLayout.phoneChipSpacing) {
                materialChip(industry.coalCost, icon: "seal.fill", width: IndustryRailLayout.phoneChipWidth)
                materialChip(industry.ironCost, icon: "cube.fill", width: IndustryRailLayout.phoneChipWidth)
            }
            HStack(spacing: IndustryRailLayout.phoneScoreSpacing) {
                iconValue("shield.fill", industry.victoryPoints ?? 0, width: IndustryRailLayout.phoneScoreWidth, tint: BrassColor.paper.color)
                labeledValue("路", industry.linkPoints ?? 0, width: IndustryRailLayout.phoneScoreWidth, tint: BrassColor.brass.color)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(BrassColor.paper.color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(industryAccessibilityLabel(industry) + industrialValueLabel(industry))
    }

    /// 建造费用:黄铜圆底钱币数字。
    private func costCoin(_ cost: Int) -> some View {
        Text("\(cost)")
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(BrassColor.coal.color)
            .frame(width: IndustryRailLayout.phoneCoin, height: IndustryRailLayout.phoneCoin)
            .background(Circle().fill(BrassColor.brass.color))
            .overlay(Circle().stroke(BrassColor.paper.color.opacity(0.4), lineWidth: 0.5))
    }

    /// 材料(煤/铁)用量:图标 + 数字,无需求时置灰显示 0。
    private func materialChip(_ value: Int, icon: String, width: CGFloat) -> some View {
        HStack(spacing: 1) {
            Image(systemName: icon)
                .font(.system(size: 7))
            Text("\(value)")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(value > 0 ? BrassColor.paper.color : BrassColor.paper.color.opacity(0.4))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: width)
        .clipped()
    }

    private func iconValue(_ icon: String, _ value: Int, width: CGFloat, tint: Color) -> some View {
        HStack(spacing: 1) {
            Image(systemName: icon)
                .font(.system(size: 7))
            Text("\(value)")
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(width: width)
        .clipped()
    }

    private func labeledValue(_ label: String, _ value: Int, width: CGFloat, tint: Color) -> some View {
        HStack(spacing: 1) {
            Text(label)
                .font(.system(size: 7, weight: .bold))
            Text("\(value)")
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(width: width)
        .clipped()
    }

    private func tabletChip(title: String?, value: Int, icon: String?, width: CGFloat) -> some View {
        HStack(spacing: 2) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
            }
            if let title {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
            }
            Text("\(value)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: width, alignment: .leading)
        .clipped()
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
