import SwiftUI

struct MatchHeaderView: View {
    let state: DemoMatchState
    let roomID: String?
    let authoritativeVersion: Int?
    let syncStatus: String?
    let isSynchronized: Bool?
    let activeTurn: ActiveTurnPresentation?
    let metrics: MatchLayoutMetrics?

    init(
        state: DemoMatchState,
        roomID: String? = nil,
        authoritativeVersion: Int? = nil,
        syncStatus: String? = nil,
        isSynchronized: Bool? = nil,
        activeTurn: ActiveTurnPresentation? = nil,
        metrics: MatchLayoutMetrics? = nil
    ) {
        self.state = state
        self.roomID = roomID
        self.authoritativeVersion = authoritativeVersion
        self.syncStatus = syncStatus
        self.isSynchronized = isSynchronized
        self.activeTurn = activeTurn
        self.metrics = metrics
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            header(spacing: 10, compact: false)
            header(spacing: 7, compact: true)
        }
        .padding(.horizontal, metrics?.formFactor == .tablet ? 12 : 8)
        .frame(height: metrics?.headerHeight ?? 44)
        .modifier(IndustrialPanelSurface(axis: .horizontal))
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
            if let activeTurn {
                ActiveTurnStatusView(presentation: activeTurn)
                    .layoutPriority(3)
            } else {
                value(compact ? "当前 -" : "当前玩家 -", icon: "person.crop.circle")
            }
            value(compact ? "A\(state.actionNumber)" : "行动 \(state.actionNumber)", icon: "bolt.fill")
            value(compact ? "\(state.deckRemaining)" : "牌库 \(state.deckRemaining)", icon: "rectangle.stack.fill")
            value("£\(state.money)", icon: "sterlingsign.circle.fill")
            value(compact ? signed(state.income) : "收入 \(signed(state.income))", icon: "chart.line.uptrend.xyaxis")
            value(compact ? "VP \(state.victoryPoints)" : "胜利点 \(state.victoryPoints)", icon: "medal.fill")
            if let syncStatus {
                syncValue(syncStatus)
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

    private func syncValue(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isSynchronized == true ? "checkmark.icloud" : "arrow.triangle.2.circlepath")
                .foregroundStyle(BrassColor.brass.color)
                .accessibilityHidden(true)
            Text(text)
                .font(BrassTypography.number)
                .monospacedDigit()
                .accessibilityLabel(text)
                .accessibilityIdentifier("real.sync")
        }
    }

    private func signed(_ value: Int) -> String {
        value >= 0 ? "+\(value)" : "\(value)"
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
            authoritativeVersion.map { "权威版本 v\($0)" },
            Optional("\(state.era)，第 \(state.round) 回合，共 \(state.roundCount) 回合"),
            activeTurn?.accessibilityLabel,
            Optional("行动 \(state.actionNumber)"),
            Optional("牌库 \(state.deckRemaining)"),
            Optional("资金 \(state.money) 英镑"),
            Optional("收入 \(signed(state.income))"),
            Optional("胜利点 \(state.victoryPoints)"),
            syncStatus.map { "同步状态 \($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: "，")
    }
}
