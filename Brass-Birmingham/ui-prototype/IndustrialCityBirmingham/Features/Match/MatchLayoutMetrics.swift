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
    let headerHeight: CGFloat
    let mapTopInset: CGFloat
    let safeAreaTrailing: CGFloat
    let marketPlacement: MarketPlacement

    var mapLegendInsets: MapLegendInsets {
        MapLegendInsets(top: mapTopInset, trailing: rightRailWidth + safeAreaTrailing)
    }

    var mapLegendInsetsWithinPaddedViewport: MapLegendInsets {
        MapLegendInsets(top: 0, trailing: mapLegendInsets.trailing)
    }

    var mapViewportInsets: MapViewportInsets {
        guard formFactor == .phone else { return .zero }
        return MapViewportInsets(
            // The map view itself is already laid out below the header. Only
            // overlays inside that local viewport belong in the camera inset.
            top: 0,
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
            leftRailWidth = 184
            rightRailWidth = 176
            handHeight = 132
            headerHeight = 48
            mapTopInset = 48
            marketPlacement = .underPlayerRail
        } else {
            formFactor = .phone
            leftRailWidth = 44
            rightRailWidth = 44
            handHeight = 92
            headerHeight = 44
            mapTopInset = 44
            marketPlacement = .bottomLeftCompact
        }
    }
}
