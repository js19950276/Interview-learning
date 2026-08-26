import SwiftUI

struct ActiveTurnStatusView: View {
    let presentation: ActiveTurnPresentation

    var body: some View {
        Label(presentation.headerText, systemImage: presentation.playerColor.symbol)
            .font(.caption.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(BrassColor.coal.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background((presentation.isLocalPlayer ? BrassColor.brass : BrassColor.paper).color)
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(BrassColor.brass.color.opacity(0.7), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityIdentifier("real.turn.status")
    }
}

struct ActiveTurnNoticeView: View {
    let presentation: ActiveTurnPresentation
    let reduceMotion: Bool

    var body: some View {
        Label(presentation.noticeText, systemImage: presentation.playerColor.symbol)
            .font(BrassTypography.title)
            .foregroundStyle(BrassColor.paper.color)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(BrassColor.coal.color.opacity(0.95))
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(BrassColor.brass.color, lineWidth: 2)
            }
            .shadow(color: Color.black.opacity(0.45), radius: 14, y: 6)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
            .accessibilityIdentifier("real.turn.notice")
            .accessibilityHidden(true)
    }
}
