import SwiftUI

struct AuthoritativePlayerDrawer: View {
    let players: [PlayerSummary]
    let localPlayerID: String
    let showsColorAssistSymbols: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("玩家顺序与花费")
                    .font(BrassTypography.title)
                    .foregroundStyle(BrassColor.brass.color)

                ForEach(players) { player in
                    HStack(spacing: 8) {
                        Image(systemName: showsColorAssistSymbols ? player.color.symbol : "circle.fill")
                            .frame(width: 24)
                            .foregroundStyle(tint(player.color))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(player))
                                .font(BrassTypography.label)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if player.isCurrent {
                                    Label("行动中", systemImage: "play.fill")
                                }
                                if player.isHost {
                                    Label("主机", systemImage: "crown.fill")
                                }
                                Label(
                                    player.isConnected ? "在线" : "离线",
                                    systemImage: player.isConnected ? "wifi" : "wifi.slash"
                                )
                            }
                            .font(.caption2)
                        }
                        Spacer(minLength: 0)
                        Text("£\(player.spent)")
                            .font(BrassTypography.number)
                    }
                    .foregroundStyle(BrassColor.paper.color)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
                    .background(
                        player.isCurrent
                            ? BrassColor.brass.color.opacity(0.22)
                            : BrassColor.iron.color.opacity(0.24)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(PlayerRailView.accessibilitySummary(
                        players: [player],
                        showsColorAssistSymbols: showsColorAssistSymbols,
                        localPlayerID: localPlayerID
                    ))
                    .accessibilityIdentifier("drawer.player.\(player.id)")
                }
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
        .background(BrassColor.coal.color.opacity(0.95))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(BrassColor.brass.color.opacity(0.65))
                .frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overlay.playerRail")
    }

    private func displayName(_ player: PlayerSummary) -> String {
        "\(player.order). \(player.name)\(player.id == localPlayerID ? "（你）" : "")"
    }

    private func tint(_ color: PlayerColor) -> Color {
        switch color {
        case .amber: BrassColor.brass.color
        case .crimson: BrassColor.danger.color
        case .teal: Color(red: 0.20, green: 0.67, blue: 0.67)
        case .violet: Color(red: 0.61, green: 0.45, blue: 0.78)
        }
    }
}

struct AuthoritativeIndustryDrawer: View {
    let industries: [IndustrySummary]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("产业板块")
                    .font(BrassTypography.title)
                    .foregroundStyle(BrassColor.brass.color)

                ForEach(industries) { industry in
                    HStack(spacing: 8) {
                        Image(systemName: industry.kind.symbol)
                            .frame(width: 24)
                        Text(name(industry.kind))
                            .font(BrassTypography.label)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("L\(industry.level) · £\(industry.cost)")
                                .font(BrassTypography.number)
                            Text(industry.isAvailable ? "可用" : "已用")
                                .font(.caption2)
                        }
                    }
                    .foregroundStyle(BrassColor.paper.color)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
                    .background(
                        BrassColor.iron.color.opacity(industry.isAvailable ? 0.32 : 0.14)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(industry))
                    .accessibilityIdentifier("drawer.industry.\(industry.id)")
                }
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
        .background(BrassColor.coal.color.opacity(0.95))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(BrassColor.brass.color.opacity(0.65))
                .frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overlay.industryRail")
    }

    private func accessibilityLabel(_ industry: IndustrySummary) -> String {
        "\(name(industry.kind))，等级 \(industry.level)，费用 \(industry.cost) 英镑，\(industry.isAvailable ? "可用" : "不可用")"
    }

    private func name(_ kind: IndustryKind) -> String {
        switch kind {
        case .cotton: "棉纺厂"
        case .manufacturer: "制造厂"
        case .pottery: "陶器厂"
        case .coal: "煤矿"
        case .iron: "炼铁厂"
        case .brewery: "啤酒厂"
        }
    }
}
