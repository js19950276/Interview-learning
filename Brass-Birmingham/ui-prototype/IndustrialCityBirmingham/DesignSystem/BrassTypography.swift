import SwiftUI

struct BrassFontToken: Equatable, Sendable {
    let textStyle: Font.TextStyle
    let weight: Font.Weight
    let design: Font.Design

    var font: Font {
        .system(textStyle, design: design, weight: weight)
    }
}

enum BrassTypography {
    static let displayToken = BrassFontToken(textStyle: .largeTitle, weight: .semibold, design: .serif)
    static let titleToken = BrassFontToken(textStyle: .title2, weight: .semibold, design: .serif)
    static let bodyToken = BrassFontToken(textStyle: .subheadline, weight: .regular, design: .rounded)
    static let labelToken = BrassFontToken(textStyle: .caption, weight: .semibold, design: .rounded)
    static let numberToken = BrassFontToken(textStyle: .subheadline, weight: .bold, design: .monospaced)

    static let display = displayToken.font
    static let title = titleToken.font
    static let body = bodyToken.font
    static let label = labelToken.font
    static let number = numberToken.font
}
