import SwiftUI

struct MatchHeaderView: View {
    let state: DemoMatchState
    let roomID: String?
    let syncStatus: String?
    let isSynchronized: Bool?
    let activeTurn: ActiveTurnPresentation?
    let metrics: MatchLayoutMetrics?
    /// 附加模式标签(短局标题),nil 不显示;时代字符串继续给地图样式解析用。
    var modeLabel: String?
    var onShowActionLog: (() -> Void)?
    /// 左上角退出键占用的宽度。顶栏底仍铺满，只把文字往右让开。
    var leadingObstruction: CGFloat = 0

    init(
        state: DemoMatchState,
        roomID: String? = nil,
        syncStatus: String? = nil,
        isSynchronized: Bool? = nil,
        activeTurn: ActiveTurnPresentation? = nil,
        metrics: MatchLayoutMetrics? = nil,
        modeLabel: String? = nil,
        onShowActionLog: (() -> Void)? = nil,
        leadingObstruction: CGFloat = 0
    ) {
        self.state = state
        self.roomID = roomID
        self.syncStatus = syncStatus
        self.isSynchronized = isSynchronized
        self.activeTurn = activeTurn
        self.metrics = metrics
        self.modeLabel = modeLabel
        self.onShowActionLog = onShowActionLog
        self.leadingObstruction = leadingObstruction
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            header(spacing: 10, compact: false)
            header(spacing: 7, compact: true)
        }
        .padding(.leading, (metrics?.formFactor == .tablet ? 12 : 8) + leadingObstruction)
        .padding(.trailing, metrics?.formFactor == .tablet ? 12 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: metrics?.headerHeight ?? 44)
        .modifier(IndustrialPanelSurface())
        .foregroundStyle(BrassColor.paper.color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("match.header")
    }

    private func header(spacing: CGFloat, compact: Bool) -> some View {
        HStack(spacing: spacing) {
            roomAccessibilityAnchor
            value(
                compact ? "\(state.era.replacingOccurrences(of: "时代", with: "")) R\(state.round)/\(state.roundCount)" : "\(state.era) · 回合 \(state.round)/\(state.roundCount)",
                icon: "arrow.triangle.2.circlepath"
            )
            if let modeLabel {
                Text(modeLabel)
                    .font(BrassTypography.label)
                    .foregroundStyle(BrassColor.brass.color)
                    .lineLimit(1)
            }
            if let activeTurn {
                ActiveTurnStatusView(presentation: activeTurn)
                    .layoutPriority(3)
            } else {
                value(compact ? "当前 -" : "当前玩家 -", icon: "person.crop.circle")
            }
            value(compact ? "行动\(state.actionNumber)" : "行动 \(state.actionNumber)", icon: "bolt.fill")
            value("£\(state.money)", icon: "sterlingsign.circle.fill")
            value(incomeText(compact: compact), icon: "chart.line.uptrend.xyaxis")
            value(compact ? "VP \(state.victoryPoints)" : "胜利点 \(state.victoryPoints)", icon: "medal.fill")
            if let onShowActionLog {
                Button(action: onShowActionLog) {
                    Label("日志", systemImage: "list.bullet.rectangle.portrait")
                        .labelStyle(.iconOnly)
                        .font(BrassTypography.number)
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrassColor.brass.color)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
                .accessibilityLabel("玩家行动日志")
                .accessibilityIdentifier("match.actionLog.toggle")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func value(_ text: String, icon: String) -> some View {
        Label {
            Text(text)
                .font(BrassTypography.number)
                .monospacedDigit()
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(BrassColor.brass.color)
        }
        .labelStyle(.titleAndIcon)
    }

    /// 收入等级是“下个收入阶段收/付的金额”(RULES.md §6.3),
    /// 不是累计变动;标明“下轮”避免被读成 +10 增量。
    private func incomeText(compact: Bool) -> String {
        let amount = state.income >= 0 ? "£\(state.income)" : "-£\(-state.income)"
        return compact ? "下轮 \(amount)" : "下轮收入 \(amount)"
    }

    @ViewBuilder
    private var roomAccessibilityAnchor: some View {
        if let roomID {
            if metrics?.formFactor == .tablet {
                Text("房间 \(roomID)")
                    .font(BrassTypography.label)
                    .foregroundStyle(BrassColor.parchmentShadow.color)
                    .accessibilityIdentifier("real.room")
            } else {
                Text("房间 \(roomID)")
                    .font(.caption2)
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .accessibilityIdentifier("real.room")
            }
        }
    }

    private var accessibilitySummary: String {
        [
            roomID.map { "房间 \($0)" },
            Optional("\(state.era)，第 \(state.round) 回合，共 \(state.roundCount) 回合"),
            activeTurn?.accessibilityLabel,
            Optional("行动 \(state.actionNumber)"),
            Optional("资金 \(state.money) 英镑"),
            Optional(state.income >= 0
                ? "下轮收入 \(state.income) 英镑"
                : "下轮需支付 \(-state.income) 英镑"),
            Optional("胜利点 \(state.victoryPoints)"),
        ]
        .compactMap { $0 }
        .joined(separator: "，")
    }
}
