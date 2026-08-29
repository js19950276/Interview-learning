import SwiftUI

enum BrassSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 24
    static let xxLarge: CGFloat = 32
    static let all = [xSmall, small, medium, large, xLarge, xxLarge]
}

enum BrassRadius {
    static let card: CGFloat = 12
    static let panel: CGFloat = 16
    static let capsule: CGFloat = 999
}

enum BrassShadow {
    static let panel = (color: Color.black.opacity(0.38), radius: CGFloat(18), y: CGFloat(10))
    static let selected = (color: BrassColor.brass.color.opacity(0.55), radius: CGFloat(14), y: CGFloat(4))
}
