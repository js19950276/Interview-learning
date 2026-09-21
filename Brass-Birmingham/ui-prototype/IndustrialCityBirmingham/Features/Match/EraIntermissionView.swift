import SwiftUI

/// 时代结算确认界面:展示每人 VP 构成与收入等级,
/// 全员确认后才进入铁路时代。
struct EraIntermissionView: View {
    let intermission: GameCore.EraIntermissionState
    let projections: [GameCore.MatchPlayerProjection]
    let localPlayerID: String
    let displayName: (GameCore.PlayerID) -> String
    let onConfirm: () -> Void

    private var rows: [(award: GameCore.EraAward, projection: GameCore.MatchPlayerProjection?)] {
        intermission.awards.map { award in
            (award, projections.first(where: { $0.id == award.playerID }))
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("运河时代结算")
                    .font(BrassTypography.title)
                    .foregroundStyle(BrassColor.brass.color)
                Text("所有玩家确认后进入铁路时代")
                    .font(BrassTypography.label)
                    .foregroundStyle(BrassColor.paper.color.opacity(0.72))

                VStack(spacing: 6) {
                    HStack {
                        Text("玩家").frame(maxWidth: .infinity, alignment: .leading)
                        Text("线路").frame(width: 44)
                        Text("产业").frame(width: 44)
                        Text("收入").frame(width: 52)
                        Text("总VP").frame(width: 52)
                    }
                    .font(.caption2)
                    .foregroundStyle(BrassColor.paper.color.opacity(0.55))

                    ForEach(rows, id: \.award.playerID.rawValue) { row in
                        playerRow(row)
                    }
                }
                .padding(12)
                .background(BrassColor.iron.color.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                confirmButton

                Text("已确认 \(intermission.confirmedPlayerIDs.count)/\(intermission.awards.count)")
                    .font(.caption2)
                    .foregroundStyle(BrassColor.paper.color.opacity(0.55))
            }
            .padding(20)
            .background(BrassColor.coal.color.opacity(0.97))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("era.intermission")
    }

    private func playerRow(_ row: (award: GameCore.EraAward, projection: GameCore.MatchPlayerProjection?)) -> some View {
        let confirmed = intermission.confirmedPlayerIDs.contains(row.award.playerID)
        return HStack(spacing: 6) {
            HStack(spacing: 4) {
                Circle()
                    .fill(row.projection.map { MatchActionLogView.displayColor($0.color) } ?? BrassColor.fog.color)
                    .frame(width: 8, height: 8)
                Text(displayName(row.award.playerID))
                    .font(BrassTypography.label)
                    .lineLimit(1)
                if confirmed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(BrassColor.legalGreen.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(row.award.linkPoints)").frame(width: 44)
            Text("\(row.award.industryPoints)").frame(width: 44)
            Text("£\(row.award.incomeLevel)").frame(width: 52)
            Text("\(row.projection?.victoryPoints ?? 0)").frame(width: 52)
        }
        .font(BrassTypography.number)
        .monospacedDigit()
        .foregroundStyle(BrassColor.paper.color)
    }

    private var localIsConfirmed: Bool {
        intermission.confirmedPlayerIDs.contains(GameCore.PlayerID(rawValue: localPlayerID))
    }

    private var confirmButton: some View {
        Button {
            onConfirm()
        } label: {
            Text(localIsConfirmed ? "已确认，等待其他玩家" : "确认进入铁路时代")
                .font(BrassTypography.label)
                .foregroundStyle(localIsConfirmed ? BrassColor.paper.color.opacity(0.6) : BrassColor.coal.color)
                .padding(.horizontal, 22)
                .frame(minHeight: 46)
                .frame(maxWidth: .infinity)
                .background(localIsConfirmed ? BrassColor.iron.color.opacity(0.7) : BrassColor.brass.color)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(localIsConfirmed)
        .accessibilityIdentifier("era.intermission.confirm")
    }
}
