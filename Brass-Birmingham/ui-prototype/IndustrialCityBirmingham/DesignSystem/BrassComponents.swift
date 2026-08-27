import SwiftUI

struct BrassPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(BrassSpacing.large)
            .background(.ultraThinMaterial)
            .background(BrassColor.coal.color.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: BrassRadius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BrassRadius.panel, style: .continuous)
                    .stroke(BrassColor.brass.color.opacity(0.45), lineWidth: 1)
            }
            .shadow(
                color: BrassShadow.panel.color,
                radius: BrassShadow.panel.radius,
                y: BrassShadow.panel.y
            )
    }
}

extension View {
    func brassPanel() -> some View {
        modifier(BrassPanel())
    }
}

struct BrassPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrassTypography.label)
            .foregroundStyle(BrassColor.coal.color)
            .padding(.horizontal, BrassSpacing.xLarge)
            .frame(minHeight: 45)
            .background((configuration.isPressed ? BrassColor.pressedBrass : BrassColor.brass).color)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
