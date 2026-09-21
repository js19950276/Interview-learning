import SwiftUI

/// 终局得分榜:按排名分组展示每人总 VP、收入等级与现金。
struct FinalScoreboardView: View {
    let standings: [[GameCore.PlayerID]]
    let projections: [GameCore.MatchPlayerProjection]
    let displayName: (GameCore.PlayerID) -> String

    private func projection(_ playerID: GameCore.PlayerID) -> GameCore.MatchPlayerProjection? {
        projections.first(where: { $0.id == playerID })
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("游戏结束")
                    .font(BrassTypography.title)
                    .foregroundStyle(BrassColor.brass.color)
                Text("最终排名")
                    .font(BrassTypography.label)
                    .foregroundStyle(BrassColor.paper.color.opacity(0.72))

                VStack(spacing: 6) {
                    HStack {
                        Text("排名 · 玩家").frame(maxWidth: .infinity, alignment: .leading)
                        Text("总VP").frame(width: 52)
                        Text("收入").frame(width: 56)
                        Text("现金").frame(width: 56)
                    }
                    .font(.caption2)
                    .foregroundStyle(BrassColor.paper.color.opacity(0.55))

                    let groups = standings.enumerated().map { ($0.offset, $0.element) }
                    ForEach(groups, id: \.0) { index, group in
                        ForEach(group, id: \.rawValue) { playerID in
                            playerRow(rank: index + 1, playerID: playerID)
                        }
                    }
                }
                .padding(12)
                .background(BrassColor.iron.color.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(20)
            .background(BrassColor.coal.color.opacity(0.97))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("game.finalScoreboard")
    }

    private func playerRow(rank: Int, playerID: GameCore.PlayerID) -> some View {
        let projection = projection(playerID)
        return HStack(spacing: 6) {
            HStack(spacing: 5) {
                Text("\(rank)")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(rank == 1 ? BrassColor.brass.color : BrassColor.paper.color.opacity(0.75))
                    .frame(width: 18)
                Circle()
                    .fill(projection.map { MatchActionLogView.displayColor($0.color) } ?? BrassColor.fog.color)
                    .frame(width: 8, height: 8)
                Text(displayName(playerID))
                    .font(BrassTypography.label)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(projection?.victoryPoints ?? 0)").frame(width: 52)
            Text("£\(projection?.incomeLevel ?? 0)").frame(width: 56)
            Text("£\(projection?.cash ?? 0)").frame(width: 56)
        }
        .font(BrassTypography.number)
        .monospacedDigit()
        .foregroundStyle(BrassColor.paper.color)
    }
}
