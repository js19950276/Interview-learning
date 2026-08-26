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
        .background(.ultraThinMaterial)
        .background(BrassColor.coal.color.opacity(0.86))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(BrassColor.brass.color.opacity(0.45))
                .frame(width: 1)
        }
        .accessibilityIdentifier(accessibilityEnabled ? "match.industryRail.content" : "")
    }

    private var railContent: some View {
        VStack(spacing: metrics.formFactor == .tablet ? 8 : 3) {
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

            ForEach(industries) { industry in
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
                    .background(selectionBackground(industry.id))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(BrassColor.brass.color.opacity(0.72), lineWidth: 1)
                    }
                    .accessibilityLabel("选择产业，\(industryAccessibilityLabel(industry))")
                    .accessibilityIdentifier("industry.select.\(industry.id)")
                    .accessibilityAddTraits(selectedIndustryIDs.contains(industry.id) ? .isSelected : [])
                } else {
                    industryContent(industry)
                }
            }
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
        .accessibilityIdentifier(accessibilityEnabled ? "industry.flip.\(industry.id)" : "")
        .accessibilityValue(flippedIndustryIDs.contains(industry.id) ? "已翻面" : "未翻面")
        .accessibilityHidden(!accessibilityEnabled)
    }

    private func selectionBackground(_ id: String) -> Color {
        selectedIndustryIDs.contains(id)
            ? BrassColor.brass.color.opacity(0.28)
            : BrassColor.iron.color.opacity(0.30)
    }

    private func tabletIndustry(_ industry: IndustrySummary) -> some View {
        HStack(spacing: 7) {
            Image(systemName: industry.kind.symbol)
                .font(.title3)
                .foregroundStyle(industry.isAvailable ? BrassColor.brass.color : BrassColor.fog.color)
                .frame(width: 26)
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
                    resource("煤", value: industry.coalCost, icon: "seal.fill")
                    resource("铁", value: industry.ironCost, icon: "cube.fill")
                    Spacer()
                    Label(industry.isAvailable ? "可用" : "已用", systemImage: industry.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption2)
                }
            }
        }
        .foregroundStyle(BrassColor.paper.color)
        .padding(7)
        .background(industry.isAvailable ? BrassColor.iron.color.opacity(0.22) : BrassColor.fog.color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(industryAccessibilityLabel(industry))
    }

    private func phoneIndustry(_ industry: IndustrySummary) -> some View {
        VStack(spacing: 0) {
            Image(systemName: industry.kind.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(industry.isAvailable ? BrassColor.brass.color : BrassColor.fog.color)
            Text("L\(industry.level)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
            Image(systemName: industry.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(industry.isAvailable ? BrassColor.paper.color : BrassColor.danger.color)
        }
        .frame(maxHeight: .infinity)
        .foregroundStyle(BrassColor.paper.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(industryAccessibilityLabel(industry))
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
