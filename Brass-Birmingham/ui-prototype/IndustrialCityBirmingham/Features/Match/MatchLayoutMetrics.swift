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
    let safeAreaTrailing: CGFloat
    let marketPlacement: MarketPlacement

    var mapLegendInsets: MapLegendInsets {
        MapLegendInsets(top: mapTopInset, trailing: rightRailWidth + safeAreaTrailing)
    }

    var mapViewportInsets: MapViewportInsets {
        guard formFactor == .phone else { return .zero }
        return MapViewportInsets(
            top: mapTopInset,
            leading: leftRailWidth,
            bottom: handHeight,
            trailing: rightRailWidth + safeAreaTrailing
        )
    }

    init(viewport: CGSize, safeAreaTrailing: CGFloat = 0) {
        self.viewport = viewport
        self.safeAreaTrailing = max(0, safeAreaTrailing)

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
