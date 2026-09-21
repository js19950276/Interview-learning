import SwiftUI

struct PlayerRailView: View {
    let players: [PlayerSummary]
    let metrics: MatchLayoutMetrics
    let localPlayerID: String?
    let showsColorAssistSymbols: Bool
    let accessibilityEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        players: [PlayerSummary],
        metrics: MatchLayoutMetrics,
        localPlayerID: String? = nil,
        showsColorAssistSymbols: Bool = true,
        accessibilityEnabled: Bool = true
    ) {
        self.players = players
        self.metrics = metrics
        self.localPlayerID = localPlayerID
        self.showsColorAssistSymbols = showsColorAssistSymbols
        self.accessibilityEnabled = accessibilityEnabled
    }

    var body: some View {
        Group {
            if metrics.formFactor == .tablet {
                tabletRail
            } else {
                phoneRail
            }
        }
        .frame(width: metrics.leftRailWidth)
        .modifier(IndustrialPanelSurface(axis: .vertical))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(BrassColor.brass.color.opacity(0.45))
                .frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilitySummary(
            players: players,
            showsColorAssistSymbols: showsColorAssistSymbols,
            localPlayerID: localPlayerID
        ))
        .accessibilityValue(Self.railAccessibilityValue(players: players))
        .accessibilityIdentifier(accessibilityEnabled ? "match.playerRail.content" : "")
        .accessibilityHidden(!accessibilityEnabled)
    }

    private var tabletRail: some View {
        VStack(spacing: 8) {
            Text("玩家顺序")
                .font(BrassTypography.label)
                .foregroundStyle(BrassColor.brass.color)

            ForEach(players) { player in
                tabletPlayer(player)
            }

            Spacer(minLength: 4)
        }
        .padding(10)
    }

    private var phoneRail: some View {
        VStack(spacing: 4) {
            ForEach(players) { player in
                ZStack(alignment: .leading) {
                    VStack(spacing: 2) {
                        Image(systemName: playerSymbol(player.color))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(playerTint(player.color))
                        Text("\(player.order)")
                            .font(BrassTypography.number)
                            .monospacedDigit()
                        Text("£\(player.spent)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(player.spent > 0 ? BrassColor.brass.color : BrassColor.paper.color.opacity(0.75))
                        phoneStatusBadges(player)
                    }
                    .frame(maxWidth: .infinity)

                    if player.isCurrent {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(BrassColor.brass.color)
                            .frame(width: 3, height: 24)
                            .padding(.leading, 1)
                    }
                }
                .foregroundStyle(BrassColor.paper.color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(player.isCurrent
                    ? playerTint(player.color).opacity(0.26)
                    : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            player.isCurrent ? playerTint(player.color) : BrassColor.fog.color.opacity(0.2),
                            lineWidth: player.isCurrent ? 2.5 : 1
                        )
                }
                .shadow(
                    color: player.isCurrent ? playerTint(player.color).opacity(0.65) : Color.clear,
                    radius: 9
                )
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: player.isCurrent)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.playerAccessibilityLabel(
                    player,
                    showsColorAssistSymbols: showsColorAssistSymbols,
                    localPlayerID: localPlayerID
                ))
                .accessibilityValue(Self.playerAccessibilityValue(player))
                .accessibilityIdentifier(accessibilityEnabled ? "match.player.\(player.id)" : "")
                .accessibilityHidden(!accessibilityEnabled)
            }
        }
        .padding(.vertical, 4)
    }

    private func tabletPlayer(_ player: PlayerSummary) -> some View {
        HStack(spacing: 7) {
            industryAvatar(player)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(displayName(player))
                        .font(BrassTypography.label)
                        .lineLimit(1)
                    if player.isHost { status("主机", icon: "crown.fill") }
                    if player.isConnected == false { status("离线", icon: "wifi.slash") }
                }
                HStack(spacing: 8) {
                    Label("£\(player.cash)", systemImage: "sterlingsign.circle.fill")
                    Label("收入 £\(player.incomeLevel)", systemImage: "chart.line.uptrend.xyaxis")
                    Label("VP \(player.victoryPoints)", systemImage: "shield.fill")
                }
                .font(BrassTypography.number)
                .monospacedDigit()
                HStack(spacing: 6) {
                    Text("本轮 £\(player.spent)")
                    if player.isCurrent {
                        status("行动", icon: "play.fill")
                            .foregroundStyle(BrassColor.brass.color)
                            .modifier(ActionBadgePulse(active: true))
                    }
                }
                .font(.caption2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(BrassColor.paper.color)
        .padding(7)
        .frame(minHeight: 56)
        .background(player.isCurrent
            ? playerTint(player.color).opacity(0.20)
            : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    player.isCurrent ? playerTint(player.color) : BrassColor.fog.color.opacity(0.25),
                    lineWidth: player.isCurrent ? 2.5 : 1
                )
        }
        .shadow(
            color: player.isCurrent ? playerTint(player.color).opacity(0.60) : Color.clear,
            radius: 9
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: player.isCurrent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.playerAccessibilityLabel(
            player,
            showsColorAssistSymbols: showsColorAssistSymbols,
            localPlayerID: localPlayerID
        ))
        .accessibilityValue(Self.playerAccessibilityValue(player))
        .accessibilityIdentifier(accessibilityEnabled ? "match.player.\(player.id)" : "")
        .accessibilityHidden(!accessibilityEnabled)
    }

    private func status(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private func phoneStatusBadges(_ player: PlayerSummary) -> some View {
        HStack(spacing: 2) {
            if player.isCurrent {
                phoneBadge("行动", emphasized: true)
                    .modifier(ActionBadgePulse(active: true))
            }
            if isLocal(player) {
                phoneBadge("你", emphasized: false)
            }
        }
    }

    private func phoneBadge(_ title: String, emphasized: Bool) -> some View {
        Text(title)
            .font(.system(size: 7, weight: .heavy, design: .rounded))
            .foregroundStyle(emphasized ? BrassColor.coal.color : BrassColor.paper.color)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(emphasized ? BrassColor.brass.color : BrassColor.fog.color.opacity(0.55))
            .clipShape(Capsule())
    }

    /// “行动”徽章呼吸闪烁,让轮到谁一目了然;开启减弱动态效果时保持常亮。
    private struct ActionBadgePulse: ViewModifier {
        let active: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var dimmed = false

        func body(content: Content) -> some View {
            content
                .opacity(active && reduceMotion ? 1 : (dimmed ? 0.45 : 1))
                .onAppear {
                    guard active, !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        dimmed = true
                    }
                }
                .onChange(of: reduceMotion) { _, isReduced in
                    guard active else { return }
                    if isReduced {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { dimmed = false }
                    } else {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            dimmed = true
                        }
                    }
                }
        }
    }

    private func isLocal(_ player: PlayerSummary) -> Bool {
        player.id == localPlayerID
    }

    private func displayName(_ player: PlayerSummary) -> String {
        "\(player.order). \(player.name)\(isLocal(player) ? "（你）" : "")"
    }

    private func playerTint(_ color: PlayerColor) -> Color {
        switch color {
        case .amber: BrassColor.brass.color
        case .crimson: BrassColor.danger.color
        case .teal: Color(red: 0.94, green: 0.94, blue: 0.90)
        case .violet: Color(red: 0.61, green: 0.45, blue: 0.78)
        }
    }

    nonisolated static func accessibilitySummary(
        players: [PlayerSummary],
        showsColorAssistSymbols: Bool,
        localPlayerID: String? = nil
    ) -> String {
        players.map {
            playerAccessibilityLabel(
                $0,
                showsColorAssistSymbols: showsColorAssistSymbols,
                localPlayerID: localPlayerID
            )
        }
        .joined(separator: "；")
    }

    nonisolated static func railAccessibilityValue(players: [PlayerSummary]) -> String {
        guard let current = players.first(where: { $0.isCurrent }) else {
            return "\(players.count) 位玩家"
        }
        return "\(players.count) 位玩家，行动：\(current.name)"
    }

    nonisolated static func playerAccessibilityValue(_ player: PlayerSummary) -> String {
        player.isCurrent ? "行动" : "等待"
    }

    nonisolated private static func playerAccessibilityLabel(
        _ player: PlayerSummary,
        showsColorAssistSymbols: Bool,
        localPlayerID: String?
    ) -> String {
        let current = player.isCurrent ? "，当前玩家" : ""
        let host = player.isHost ? "，主机" : ""
        let local = player.id == localPlayerID ? "，你" : ""
        let ready = player.isReady ? "已就绪" : "未就绪"
        let connected = player.isConnected ? "在线" : "离线"
        let shape = showsColorAssistSymbols ? "，\(player.color.localizedShapeName)" : ""
        return "顺序 \(player.order)，\(player.name)，\(player.color.localizedName)\(shape)，已花 \(player.spent) 英镑，\(ready)，\(connected)\(current)\(host)\(local)"
    }

    /// 玩家头像:颜色圆环 + 名字首字(参照数字版玩家卡)。
    private func industryAvatar(_ player: PlayerSummary) -> some View {
        ZStack {
            Circle()
                .fill(playerTint(player.color).opacity(0.18))
                .frame(width: 40, height: 40)
            Circle()
                .stroke(playerTint(player.color), lineWidth: 2)
                .frame(width: 40, height: 40)
            Text(String(player.name.prefix(1)))
                .font(.system(size: 16, weight: .bold, design: .serif))
                .foregroundStyle(playerTint(player.color))
        }
    }

    private func playerSymbol(_ color: PlayerColor) -> String {
        showsColorAssistSymbols ? color.symbol : "circle.fill"
    }

}
