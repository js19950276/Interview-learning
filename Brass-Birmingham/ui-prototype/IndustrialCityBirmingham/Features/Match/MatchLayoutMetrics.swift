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
    let safeAreaLeading: CGFloat
    let formFactor: MatchFormFactor
    let leftRailWidth: CGFloat
    let rightRailWidth: CGFloat
    let handHeight: CGFloat
    let headerHeight: CGFloat
    let mapTopInset: CGFloat
    let safeAreaTrailing: CGFloat
    let marketPlacement: MarketPlacement

    var mapLegendInsets: MapLegendInsets {
        // 路线图例贴在地图右下角:让开右手产业栏、横屏安全区和底部手牌。
        MapLegendInsets(
            top: 0,
            trailing: rightRailWidth + safeAreaTrailing + 8,
            bottom: handHeight + 8
        )
    }

    var mapLegendInsetsWithinPaddedViewport: MapLegendInsets {
        mapLegendInsets
    }

    var mapViewportInsets: MapViewportInsets {
        // The map view itself is already laid out below the header. Only
        // overlays inside that local viewport belong in the camera inset.
        // 手机端手牌条上方还有常驻浮层(煤铁市场/行动按钮/图例,约 88pt),
        // 相机下边距必须把整条浮层带算进去,否则平移到底部时底部城市被盖住。
        // 左边距计入横屏安全区(灵动岛一侧),最西边的什鲁斯伯里才不会被挡。
        // 右边距额外加“名牌净空”:城市名牌以节点为中心横向延展,
        // 不留余量时最东侧(德比/纳尼顿等)的名牌会滑进产业栏下面。
        let bottom = formFactor == .phone ? handHeight + 88 : handHeight
        return MapViewportInsets(
            top: 0,
            leading: leftRailWidth + safeAreaLeading,
            bottom: bottom,
            trailing: rightRailWidth + safeAreaTrailing + Self.railLabelClearance
        )
    }

    /// 左右栏不再叠锻铁框，内容可以用满栏宽。
    static let panelEdgeInset: CGFloat = 0

    /// 右栏内侧为城市名牌保留的横向净空:名牌以节点为中心、半宽可达 45pt
    /// (如“特伦特河畔伯顿”)。90 = 默认居中偏移 45(东侧名牌完全离栏)
    /// + 最大平移时的边缘余量,确保任何缩放/平移下名牌都不滑进产业栏。
    static let railLabelClearance: CGFloat = 90

    init(viewport: CGSize, safeAreaLeading: CGFloat = 0, safeAreaTrailing: CGFloat = 0) {
        self.viewport = viewport
        self.safeAreaLeading = max(0, safeAreaLeading)
        self.safeAreaTrailing = max(0, safeAreaTrailing)

        if viewport.width >= Self.tabletWidthThreshold {
            formFactor = .tablet
            leftRailWidth = 184
            rightRailWidth = 176
            handHeight = 132
            headerHeight = 48
            mapTopInset = 48
            marketPlacement = .bottomLeftCompact
        } else {
            formFactor = .phone
            leftRailWidth = 44
            // 右栏要容纳垫板式产业卡(费用/煤铁/VP/路分),比左栏宽一些。
            rightRailWidth = 56
            handHeight = 92
            headerHeight = 44
            mapTopInset = 44
            marketPlacement = .bottomLeftCompact
        }
    }
}
