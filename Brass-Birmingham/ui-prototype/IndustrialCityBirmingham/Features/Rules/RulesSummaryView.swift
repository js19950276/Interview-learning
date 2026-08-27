import SwiftUI

struct RulesSummaryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrassSpacing.large) {
                Text("开发规则摘要")
                    .font(BrassTypography.title)
                    .foregroundStyle(BrassColor.brass.color)
                summary("规则依据", "裁决以项目 RULES.md 所列 Roxley 英文规则为优先依据。")
                summary("时代", "游戏分为运河时代与铁路时代。")
                summary("行动", "六种行动为建造、铺网、发展、出售、贷款、侦察；玩家也可以跳过。")
                summary("资源", "煤必须连通并优先使用最近来源；铁不需要连通；啤酒使用独立的来源规则。")
            }
            .brassPanel()
            .padding(BrassSpacing.large)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(BrassColor.coal.color.ignoresSafeArea())
        .navigationTitle("规则")
    }

    private func summary(_ heading: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: BrassSpacing.small) {
            Text(heading)
                .font(BrassTypography.label)
                .foregroundStyle(BrassColor.brass.color)
            Text(detail)
                .font(BrassTypography.body)
                .foregroundStyle(BrassColor.paper.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
