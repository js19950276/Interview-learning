import SwiftUI

struct AuthoritativePlayerDrawer: View {
    let players: [PlayerSummary]
    let localPlayerID: String
    let showsColorAssistSymbols: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("玩家")
                    .font(BrassTypography.title)
                    .foregroundStyle(BrassColor.brass.color)

                ForEach(players) { player in
                    playerCard(player)
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

    /// 参考数字版样式的玩家卡:头像色环 + 名字 + 现金/收入/VP 数据行。
    private func playerCard(_ player: PlayerSummary) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(tint(player.color).opacity(0.18))
                    .frame(width: 44, height: 44)
                Circle()
                    .stroke(tint(player.color), lineWidth: 2.5)
                    .frame(width: 44, height: 44)
                Text(String(displayName(player).prefix(1)))
                    .font(.system(size: 17, weight: .bold, design: .serif))
                    .foregroundStyle(tint(player.color))
            }
            .overlay(alignment: .topTrailing) {
                if player.isCurrent {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(BrassColor.legalGreen.color)
                        .offset(x: 3, y: -3)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(displayName(player))
                        .font(BrassTypography.label)
                        .lineLimit(1)
                    if player.isHost {
                        Image(systemName: "crown.fill")
                            .font(.caption2)
                            .foregroundStyle(BrassColor.brass.color)
                    }
                    if player.isConnected == false {
                        Image(systemName: "wifi.slash")
                            .font(.caption2)
                            .foregroundStyle(BrassColor.danger.color)
                    }
                }
                HStack(spacing: 12) {
                    statRow(icon: "sterlingsign.circle.fill", value: "£\(player.cash)")
                    statRow(icon: "chart.line.uptrend.xyaxis", value: "£\(player.incomeLevel)")
                    statRow(icon: "shield.fill", value: "\(player.victoryPoints)")
                    statRow(icon: "clock.arrow.circlepath", value: "£\(player.spent)")
                }
                .foregroundStyle(BrassColor.paper.color.opacity(0.85))
            }

            Spacer(minLength: 0)

            Text("\(player.order)")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(player.isCurrent ? BrassColor.brass.color : BrassColor.paper.color.opacity(0.6))
                .frame(width: 26, height: 26)
                .background(Circle().fill(
                    player.isCurrent ? BrassColor.brass.color.opacity(0.28) : BrassColor.fog.color.opacity(0.25)
                ))
        }
        .foregroundStyle(BrassColor.paper.color)
        .padding(8)
        .background(
            player.isCurrent
                ? BrassColor.brass.color.opacity(0.22)
                : BrassColor.iron.color.opacity(0.24)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    player.isCurrent ? BrassColor.brass.color.opacity(0.7) : Color.clear,
                    lineWidth: 1.5
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PlayerRailView.accessibilitySummary(
            players: [player],
            showsColorAssistSymbols: showsColorAssistSymbols,
            localPlayerID: localPlayerID
        ))
        .accessibilityIdentifier("drawer.player.\(player.id)")
    }

    private func statRow(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
        }
    }

    private func displayName(_ player: PlayerSummary) -> String {
        "\(player.order). \(player.name)\(player.id == localPlayerID ? "（你）" : "")"
    }

    private func tint(_ color: PlayerColor) -> Color {
        switch color {
        case .amber: BrassColor.brass.color
        case .crimson: BrassColor.danger.color
        case .teal: Color(red: 0.94, green: 0.94, blue: 0.90)
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
                            Text("L\(industry.level) · £\(industry.cost) · 剩\(industry.remainingTotal ?? 0)")
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
