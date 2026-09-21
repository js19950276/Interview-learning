import SwiftUI

/// 玩家行动日志弹层:按权威事件顺序列出每个人的操作路径。
struct MatchActionLogView: View {
    let entries: [MatchActionLogEntry]
    let playerLabel: (GameCore.PlayerID) -> String
    let playerColor: (GameCore.PlayerID) -> Color
    @Environment(\.dismiss) private var dismiss

    static func displayColor(_ color: GameCore.PlayerColor) -> Color {
        switch color {
        case .red: BrassColor.danger.color
        case .yellow: BrassColor.brass.color
        case .blue: Color(red: 0.94, green: 0.94, blue: 0.90)
        case .purple: Color(red: 0.61, green: 0.45, blue: 0.78)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle.portrait")
                            .font(.system(size: 30))
                            .foregroundStyle(BrassColor.paper.color.opacity(0.4))
                        Text("暂无行动记录")
                            .font(BrassTypography.title)
                            .foregroundStyle(BrassColor.paper.color)
                        Text("玩家开始行动后，这里会按顺序记录每一次操作")
                            .font(BrassTypography.label)
                            .foregroundStyle(BrassColor.paper.color.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(entries) { entry in
                                    row(entry)
                                        .id(entry.id)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        .defaultScrollAnchor(.bottom)
                        .onAppear {
                            if let last = entries.last?.id {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .background(BrassColor.coal.color.ignoresSafeArea())
            .navigationTitle("行动日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("match.actionLog.done")
                }
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("match.actionLog.sheet")
    }

    private func row(_ entry: MatchActionLogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(playerColor(entry.actorID))
                .frame(width: 9, height: 9)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(playerLabel(entry.actorID)) · 第\(entry.roundNumber)轮 · 行动\(entry.actionNumber)")
                    .font(.caption2)
                    .foregroundStyle(BrassColor.paper.color.opacity(0.6))
                Text(entry.summary)
                    .font(BrassTypography.label)
                    .foregroundStyle(BrassColor.paper.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrassColor.iron.color.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
