import SwiftUI

/// 左侧玩家栏的宽度预算。每一行都落在栏宽里，避免名字和分数互相盖住。
nonisolated enum PlayerRailLayout {
    static let phoneSymbol: CGFloat = 15
    /// “行动”两个字加胶囊内边距，不能再和“你”并排。
    static let phoneBadgeWidth: CGFloat = 26

    static let avatar: CGFloat = 36
    static let cardPadding: CGFloat = 6
    static let columnSpacing: CGFloat = 6
    static let cashWidth: CGFloat = 50
    static let victoryWidth: CGFloat = 42
    static let statSpacing: CGFloat = 6
    static let incomeWidth: CGFloat = 72
    static let spentWidth: CGFloat = 64

    static func phoneClearWidth(railWidth: CGFloat) -> CGFloat {
        railWidth - MatchLayoutMetrics.panelEdgeInset * 2
    }

    static func phoneLinesFit(railWidth: CGFloat) -> Bool {
        let clear = phoneClearWidth(railWidth: railWidth)
        return clear > 0 && phoneSymbol <= clear && phoneBadgeWidth <= clear
    }

    static func textColumn(railWidth: CGFloat) -> CGFloat {
        railWidth - MatchLayoutMetrics.panelEdgeInset * 2 - cardPadding * 2 - avatar - columnSpacing
    }

    static func rowsFit(railWidth: CGFloat) -> Bool {
        let column = textColumn(railWidth: railWidth)
        let moneyRow = cashWidth + statSpacing + victoryWidth
        return column > 0 && moneyRow <= column && incomeWidth <= column && spentWidth <= column
    }
}

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
        .padding(.horizontal, MatchLayoutMetrics.panelEdgeInset)
        .frame(width: metrics.leftRailWidth)
        .modifier(IndustrialPanelSurface())
        .clipped()
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BrassColor.brass.color)
                .lineLimit(1)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(players) { player in
                        tabletPlayer(player)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        }
        .padding(.vertical, 8)
    }

    private var phoneRail: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(players) { player in
                    phonePlayer(player)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: .infinity)
    }

    private func phonePlayer(_ player: PlayerSummary) -> some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 1) {
                Image(systemName: playerSymbol(player.color))
                    .font(.system(size: PlayerRailLayout.phoneSymbol, weight: .bold))
                    .foregroundStyle(playerTint(player.color))
                Text("\(player.order)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                Text("£\(player.spent)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(player.spent > 0 ? BrassColor.brass.color : BrassColor.paper.color.opacity(0.75))
                phoneStatusBadges(player)
            }
            .frame(maxWidth: .infinity)

            if player.isCurrent {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(BrassColor.brass.color)
                    .frame(width: 3, height: 18)
            }
        }
        .foregroundStyle(BrassColor.paper.color)
        .frame(maxWidth: .infinity, minHeight: 44)
        .fixedSize(horizontal: false, vertical: true)
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

    private func tabletPlayer(_ player: PlayerSummary) -> some View {
        HStack(alignment: .center, spacing: PlayerRailLayout.columnSpacing) {
            industryAvatar(player)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(displayName(player))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if player.isHost {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(BrassColor.brass.color)
                            .accessibilityLabel("主机")
                    }
                    if player.isConnected == false {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 10))
                            .foregroundStyle(BrassColor.danger.color)
                            .accessibilityLabel("离线")
                    }
                }
                HStack(spacing: PlayerRailLayout.statSpacing) {
                    tabletStat("£\(player.cash)", icon: "sterlingsign.circle.fill", width: PlayerRailLayout.cashWidth)
                    tabletStat("VP \(player.victoryPoints)", icon: "shield.fill", width: PlayerRailLayout.victoryWidth)
                }
                tabletStat(
                    "收入 £\(player.incomeLevel)",
                    icon: "chart.line.uptrend.xyaxis",
                    width: PlayerRailLayout.incomeWidth
                )
                HStack(spacing: PlayerRailLayout.statSpacing) {
                    tabletStat("本轮 £\(player.spent)", icon: "clock", width: PlayerRailLayout.spentWidth)
                    if player.isCurrent {
                        status("行动", icon: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(BrassColor.brass.color)
                            .lineLimit(1)
                            .modifier(ActionBadgePulse(active: true))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(BrassColor.paper.color)
        .padding(PlayerRailLayout.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
        VStack(spacing: 1) {
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
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(emphasized ? BrassColor.coal.color : BrassColor.paper.color)
            .frame(width: PlayerRailLayout.phoneBadgeWidth)
            .padding(.vertical, 1)
            .background(emphasized ? BrassColor.brass.color : BrassColor.fog.color.opacity(0.55))
            .clipShape(Capsule())
    }

    private func tabletStat(_ text: String, icon: String, width: CGFloat) -> some View {
        Label {
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .monospacedDigit()
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 10))
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: width, alignment: .leading)
        .clipped()
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
                .frame(width: PlayerRailLayout.avatar, height: PlayerRailLayout.avatar)
            Circle()
                .stroke(playerTint(player.color), lineWidth: 2)
                .frame(width: PlayerRailLayout.avatar, height: PlayerRailLayout.avatar)
            Text(String(player.name.prefix(1)))
                .font(.system(size: 16, weight: .bold, design: .serif))
                .foregroundStyle(playerTint(player.color))
        }
    }

    private func playerSymbol(_ color: PlayerColor) -> String {
        showsColorAssistSymbols ? color.symbol : "circle.fill"
    }

}
