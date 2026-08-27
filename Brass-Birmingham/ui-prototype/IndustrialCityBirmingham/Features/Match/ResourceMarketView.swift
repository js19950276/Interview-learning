import SwiftUI

enum ResourceMarketPresentation {
    case compact
    case full
    case overlay
}

struct ResourceMarketView: View {
    let coal: MarketSummary
    let iron: MarketSummary
    let presentation: ResourceMarketPresentation
    var reduceMotion = false
    var onExpand: () -> Void = {}
    var accessibilityEnabled = true

    var body: some View {
        Group {
            switch presentation {
            case .compact:
                compactSummary
            case .full:
                fullMarket
            case .overlay:
                expandedOverlay
            }
        }
    }

    private var compactSummary: some View {
        Button(action: onExpand) {
            HStack(spacing: 6) {
                compactItem(title: "煤", icon: "seal.fill", market: coal, identifier: "market.coal")
                compactItem(title: "铁", icon: "cube.fill", market: iron, identifier: "market.iron")
                Image(systemName: "chevron.up")
                    .font(.caption2.bold())
                    .foregroundStyle(BrassColor.brass.color)
                    .frame(width: 20, height: 32)
            }
            .padding(5)
            .background(.ultraThinMaterial)
            .background(BrassColor.coal.color.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(BrassColor.brass.color.opacity(0.55), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel("展开资源市场")
        .accessibilityIdentifier("market.expand")
    }

    private var fullMarket: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("资源市场")
                .font(BrassTypography.label)
                .foregroundStyle(BrassColor.brass.color)
            ladder(title: "煤炭", icon: "seal.fill", market: coal, identifier: "market.coal")
            ladder(title: "钢铁", icon: "cube.fill", market: iron, identifier: "market.iron")
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .background(BrassColor.coal.color.opacity(0.9))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BrassColor.brass.color.opacity(0.45))
                .frame(height: 1)
        }
    }

    private var expandedOverlay: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("资源市场")
                    .font(BrassTypography.title)
                Spacer()
                Button(action: onExpand) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("关闭资源市场")
            }
            ladder(title: "煤炭", icon: "seal.fill", market: coal, identifier: "market.coal")
            ladder(title: "钢铁", icon: "cube.fill", market: iron, identifier: "market.iron")
        }
        .foregroundStyle(BrassColor.paper.color)
        .padding(14)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial)
        .background(BrassColor.coal.color.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(BrassColor.brass.color.opacity(0.75), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.48), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overlay.resourceMarket")
    }

    private func compactItem(
        title: String,
        icon: String,
        market: MarketSummary,
        identifier: String
    ) -> some View {
        Label {
            Text("\(title) \(market.remaining) · £\(market.cheapestPrice)")
                .font(.caption2.bold().monospacedDigit())
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: market)
        } icon: {
            Image(systemName: icon)
        }
        .foregroundStyle(BrassColor.paper.color)
        .frame(minHeight: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(title: title, market: market))
        .accessibilityIdentifier(accessibilityEnabled ? identifier : "")
        .accessibilityHidden(!accessibilityEnabled)
    }

    private func ladder(
        title: String,
        icon: String,
        market: MarketSummary,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(title, systemImage: icon)
                    .font(BrassTypography.label)
                Spacer()
                Text("余 \(market.remaining) · 最低 £\(market.cheapestPrice)")
                    .font(BrassTypography.number)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: market)
            }
            HStack(spacing: 3) {
                ForEach(Array(market.ladder.enumerated()), id: \.offset) { index, price in
                    Text("\(price)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(index < market.remaining ? BrassColor.coal.color : BrassColor.paper.color)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(index < market.remaining ? BrassColor.brass.color : BrassColor.fog.color.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
        }
        .foregroundStyle(BrassColor.paper.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(title: title, market: market))
        .accessibilityIdentifier(accessibilityEnabled ? identifier : "")
        .accessibilityHidden(!accessibilityEnabled)
    }

    private func accessibilityLabel(title: String, market: MarketSummary) -> String {
        "\(title)市场，剩余 \(market.remaining)，当前最低价格 \(market.cheapestPrice) 英镑"
    }
}
