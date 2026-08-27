import SwiftUI

struct ActionGridView: View {
    let allowedActions: Set<GameAction>
    let onSelect: (GameAction) -> Void
    let onClose: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 54, maximum: 72), spacing: 6, alignment: .center)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(GameAction.allCases) { action in
                actionButton(action)
            }
            closeButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 58)
        .modifier(IndustrialPanelSurface(axis: .horizontal))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(BrassColor.brass.color.opacity(0.7), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.38), radius: 9, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overlay.actionGrid")
    }

    private func actionButton(_ action: GameAction) -> some View {
        let isAllowed = allowedActions.contains(action)
        return Button {
            onSelect(action)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: ActionDisplay.symbol(for: action))
                    .font(.system(size: 15, weight: .semibold))
                Text(ActionDisplay.title(for: action))
                    .font(.caption2.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, 4)
            .foregroundStyle(BrassColor.paper.color)
            .background(BrassColor.forgedIron.color.opacity(0.84))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(BrassColor.brass.color.opacity(isAllowed ? 0.52 : 0.22), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .disabled(!isAllowed)
        .opacity(isAllowed ? 1 : 0.32)
        .accessibilityLabel(ActionDisplay.title(for: action))
        .accessibilityIdentifier("action.\(action.rawValue)")
    }

    private var closeButton: some View {
        Button(action: onClose) {
            VStack(spacing: 3) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                Text("关闭")
                    .font(.caption2.bold())
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, 4)
            .foregroundStyle(BrassColor.paper.color)
            .background(BrassColor.danger.color.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityIdentifier("action.close")
    }
}
