import SwiftUI

nonisolated enum IndustrialMatchAsset: String, CaseIterable, Sendable {
    case ironHorizontal = "match-iron-horizontal"
    case ironVertical = "match-iron-vertical"
    case woodFill = "match-wood-fill"
    case parchmentLabel = "match-parchment-label"
    case cardTexture = "match-card-texture"
    case brassCorner = "match-brass-corner"
    case cotton = "industry-cotton-medallion"
    case manufacturer = "industry-manufacturer-medallion"
    case pottery = "industry-pottery-medallion"
    case coal = "industry-coal-medallion"
    case iron = "industry-iron-medallion"
    case brewery = "industry-brewery-medallion"

    var name: String { rawValue }

    static let required = allCases

    static func industryMedallion(_ kind: IndustryKind) -> IndustrialMatchAsset {
        switch kind {
        case .cotton: .cotton
        case .manufacturer: .manufacturer
        case .pottery: .pottery
        case .coal: .coal
        case .iron: .iron
        case .brewery: .brewery
        }
    }
}

struct IndustrialPanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(BrassColor.darkWood.color.opacity(0.96))
    }
}

struct ParchmentContextSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(BrassColor.coal.color)
            .padding(.horizontal, 10)
            .background {
                Image(IndustrialMatchAsset.parchmentLabel.name)
                    .resizable(
                        capInsets: EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18),
                        resizingMode: .stretch
                    )
            }
    }
}
