import SwiftUI

struct HomeView: View {
    let onNavigate: (AppRoute) -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    BrassColor.coal.color,
                    BrassColor.iron.color.opacity(0.72),
                    BrassColor.fog.color.opacity(0.5)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: BrassSpacing.xLarge) {
                    Text("工业城市伯明翰")
                        .font(BrassTypography.display)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(BrassColor.paper.color)
                        .accessibilityIdentifier("home.title")

                    VStack(spacing: BrassSpacing.medium) {
                        Button("在线房间") { onNavigate(.online) }
                            .accessibilityIdentifier("home.online")
                        Button("附近离线房间") { onNavigate(.nearby) }
                            .accessibilityIdentifier("home.nearby")
                    }
                    .buttonStyle(BrassPrimaryButtonStyle())

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 88), spacing: BrassSpacing.small)],
                        spacing: BrassSpacing.small
                    ) {
                        secondaryButton("规则", id: "home.rules", route: .rules)
                        secondaryButton("设置", id: "home.settings", route: .settings)
                        secondaryButton("UI 展示", id: "home.gallery", route: .gallery)
                    }
                }
                .brassPanel()
                .padding(BrassSpacing.xLarge)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("snapshot.ready")
    }

    private func secondaryButton(_ title: String, id: String, route: AppRoute) -> some View {
        Button(title) { onNavigate(route) }
            .font(BrassTypography.label)
            .foregroundStyle(BrassColor.paper.color)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(BrassColor.fog.color.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: BrassRadius.card))
            .accessibilityIdentifier(id)
    }
}
