import CoreGraphics

nonisolated enum MatchFormFactor: Equatable {
    case phone
    case tablet
}

nonisolated enum MarketPlacement: Equatable {
    case bottomLeftCompact
    case underPlayerRail
}

nonisolated struct MatchLayoutMetrics: Equatable {
    static let tabletWidthThreshold: CGFloat = 1_000

    let viewport: CGSize
    let formFactor: MatchFormFactor
    let leftRailWidth: CGFloat
    let rightRailWidth: CGFloat
    let handHeight: CGFloat
    let mapTopInset: CGFloat
    let marketPlacement: MarketPlacement

    var mapLegendInsets: MapLegendInsets {
        MapLegendInsets(top: mapTopInset, trailing: rightRailWidth)
    }

    init(viewport: CGSize) {
        self.viewport = viewport

        if viewport.width >= Self.tabletWidthThreshold {
            formFactor = .tablet
            leftRailWidth = 220
            rightRailWidth = 210
            handHeight = 132
            mapTopInset = 58
            marketPlacement = .underPlayerRail
        } else {
            formFactor = .phone
            leftRailWidth = 44
            rightRailWidth = 44
            handHeight = 92
            mapTopInset = 76
            marketPlacement = .bottomLeftCompact
        }
    }
}
