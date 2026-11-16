import SpriteKit

nonisolated struct MapViewportInsets: Equatable, Sendable {
    static let zero = MapViewportInsets(top: 0, leading: 0, bottom: 0, trailing: 0)

    let top: CGFloat
    let leading: CGFloat
    let bottom: CGFloat
    let trailing: CGFloat

    func clamped(to viewportSize: CGSize) -> MapViewportInsets {
        let width = max(viewportSize.width, 1)
        let height = max(viewportSize.height, 1)
        let leading = min(max(self.leading, 0), max(width - 1, 0))
        let trailing = min(max(self.trailing, 0), max(width - leading - 1, 0))
        let top = min(max(self.top, 0), max(height - 1, 0))
        let bottom = min(max(self.bottom, 0), max(height - top - 1, 0))
        return MapViewportInsets(
            top: top,
            leading: leading,
            bottom: bottom,
            trailing: trailing
        )
    }
}

struct MapViewportMetrics: Equatable {
    static let maximumZoom: CGFloat = 2.8
    /// aspect-fill 锚点:semanticZoom 达到该值时相机 scale=1,地图铺满视口并裁切。
    /// 它不是缩放下限——下限按视口动态计算(见 zoomFloor)。
    static let aspectFillZoom: CGFloat = 0.75
    /// “自动整幅”哨兵:低于任何可能的动态下限,经钳制落到当前视口的整幅档。
    /// 取 0 是为了让哨兵在捏合(乘法)与视口旋转后依然指向下限。
    static let autoFitZoom: CGFloat = 0

    let logicalSize: CGSize
    let viewportSize: CGSize
    let semanticZoom: CGFloat
    let viewportInsets: MapViewportInsets

    init(
        logicalSize: CGSize,
        viewportSize: CGSize,
        semanticZoom: CGFloat,
        viewportInsets: MapViewportInsets = .zero
    ) {
        self.logicalSize = logicalSize
        self.viewportSize = CGSize(
            width: max(viewportSize.width, 1),
            height: max(viewportSize.height, 1)
        )
        self.viewportInsets = viewportInsets.clamped(to: self.viewportSize)
        let floor = Self.fitAllZoom(
            logicalSize: logicalSize,
            viewportSize: self.viewportSize,
            viewportInsets: self.viewportInsets
        )
        self.semanticZoom = min(max(semanticZoom, floor), Self.maximumZoom)
    }

    /// 整幅地图恰好装进未遮挡视口的 semanticZoom,即当前视口的缩放下限。
    var zoomFloor: CGFloat {
        Self.fitAllZoom(
            logicalSize: logicalSize,
            viewportSize: viewportSize,
            viewportInsets: viewportInsets
        )
    }

    /// 进场初始档:整幅地图恰好铺满整个视口(忽略浮层边距,手牌/市场浮在图上)。
    /// 区别于 zoomFloor——那档把版图挤进未遮挡窄带,在手机横屏上会缩成一小团;
    /// 它只作初始取景,捏合缩出的下限仍是 zoomFloor(整幅且不被浮层遮挡)。
    var overviewZoom: CGFloat {
        Self.fitAllZoom(
            logicalSize: logicalSize,
            viewportSize: viewportSize,
            viewportInsets: .zero
        )
    }

    private static func fitAllZoom(
        logicalSize: CGSize,
        viewportSize: CGSize,
        viewportInsets: MapViewportInsets
    ) -> CGFloat {
        let aspectFill = max(
            viewportSize.width / logicalSize.width,
            viewportSize.height / logicalSize.height
        )
        let unobscured = unobscuredRect(viewportSize: viewportSize, insets: viewportInsets)
        // 向下偏置一个相对 epsilon:整幅档要经过多步除法反推为可见尺寸,
        // 不偏置的话浮点往返误差会让可见边长以几个 ulp 之差跌破版图边长,
        // “完全可见即锁定居中”的判定就会失守。1e-9 的缩放差不可感知。
        return aspectFillZoom
            * min(
                unobscured.width / logicalSize.width,
                unobscured.height / logicalSize.height
            )
            / aspectFill
            * (1 - 1e-9)
    }

    var aspectFillPointsPerSceneUnit: CGFloat {
        max(viewportSize.width / logicalSize.width, viewportSize.height / logicalSize.height)
    }

    var cameraScale: CGFloat {
        Self.aspectFillZoom / semanticZoom
    }

    var sceneUnitsPerPoint: CGFloat {
        cameraScale / aspectFillPointsPerSceneUnit
    }

    var visibleSceneSize: CGSize {
        CGSize(
            width: viewportSize.width * sceneUnitsPerPoint,
            height: viewportSize.height * sceneUnitsPerPoint
        )
    }

    var unobscuredViewportRect: CGRect {
        Self.unobscuredRect(viewportSize: viewportSize, insets: viewportInsets)
    }

    private static func unobscuredRect(
        viewportSize: CGSize,
        insets: MapViewportInsets
    ) -> CGRect {
        CGRect(
            x: insets.leading,
            y: insets.top,
            width: max(
                viewportSize.width - insets.leading - insets.trailing,
                1
            ),
            height: max(
                viewportSize.height - insets.top - insets.bottom,
                1
            )
        )
    }

    var unobscuredSceneSize: CGSize {
        CGSize(
            width: unobscuredViewportRect.width * sceneUnitsPerPoint,
            height: unobscuredViewportRect.height * sceneUnitsPerPoint
        )
    }

    var unobscuredSceneCenterOffset: CGPoint {
        let viewCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        return CGPoint(
            x: (unobscuredViewportRect.midX - viewCenter.x) * sceneUnitsPerPoint,
            y: -(unobscuredViewportRect.midY - viewCenter.y) * sceneUnitsPerPoint
        )
    }

    func sceneTranslation(forDrag drag: CGSize) -> CGPoint {
        CGPoint(
            x: -drag.width * sceneUnitsPerPoint,
            y: drag.height * sceneUnitsPerPoint
        )
    }

    func clampedCameraCenter(_ proposedCenter: CGPoint) -> CGPoint {
        let offset = unobscuredSceneCenterOffset
        let proposedUnobscuredCenter = CGPoint(
            x: proposedCenter.x + offset.x,
            y: proposedCenter.y + offset.y
        )
        let clampedUnobscuredCenter = CGPoint(
            x: clampedCoordinate(
                proposedUnobscuredCenter.x,
                logicalLength: logicalSize.width,
                visibleLength: unobscuredSceneSize.width
            ),
            y: clampedCoordinate(
                proposedUnobscuredCenter.y,
                logicalLength: logicalSize.height,
                visibleLength: unobscuredSceneSize.height
            )
        )
        return CGPoint(
            x: clampedUnobscuredCenter.x - offset.x,
            y: clampedUnobscuredCenter.y - offset.y
        )
    }

    func unobscuredSceneRect(cameraCenter: CGPoint) -> CGRect {
        let center = CGPoint(
            x: cameraCenter.x + unobscuredSceneCenterOffset.x,
            y: cameraCenter.y + unobscuredSceneCenterOffset.y
        )
        return CGRect(
            x: center.x - unobscuredSceneSize.width / 2,
            y: center.y - unobscuredSceneSize.height / 2,
            width: unobscuredSceneSize.width,
            height: unobscuredSceneSize.height
        )
    }

    private func clampedCoordinate(
        _ proposedCoordinate: CGFloat,
        logicalLength: CGFloat,
        visibleLength: CGFloat
    ) -> CGFloat {
        guard visibleLength < logicalLength else { return logicalLength / 2 }
        let halfVisibleLength = visibleLength / 2
        return min(max(proposedCoordinate, halfVisibleLength), logicalLength - halfVisibleLength)
    }
}

@MainActor
final class GameMapScene: SKScene {
    static let logicalSize = CGSize(width: 2_732, height: 2_048)

    var onTargetTap: ((String) -> Void)?
    private(set) var viewportMetrics = MapViewportMetrics(
        logicalSize: logicalSize,
        viewportSize: logicalSize,
        semanticZoom: MapViewportMetrics.autoFitZoom
    )

    private let mapCamera = SKCameraNode()
    private let contentLayer = SKNode()
    private var semanticZoom = MapViewportMetrics.autoFitZoom
    private var translation: CGPoint = .zero

    override init() {
        super.init(size: Self.logicalSize)
        scaleMode = .aspectFill
        anchorPoint = .zero
        backgroundColor = .black

        let texture = SKTexture(imageNamed: "IndustrialMap")
        texture.filteringMode = .linear
        let background = SKSpriteNode(texture: texture, size: Self.logicalSize)
        background.anchorPoint = .zero
        background.position = .zero
        background.zPosition = -100
        background.name = "industrial-background"
        addChild(background)

        contentLayer.name = "map-content"
        addChild(contentLayer)

        mapCamera.position = CGPoint(x: Self.logicalSize.width / 2, y: Self.logicalSize.height / 2)
        addChild(mapCamera)
        camera = mapCamera
        applyCameraState()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(state: DemoMatchState, highlightedIDs: Set<String>) {
        contentLayer.removeAllChildren()
        let locationsByID = Dictionary(uniqueKeysWithValues: state.locations.map { ($0.id, $0) })
        let currentEra = MapRouteEraStyle.currentEra(from: state.era)

        for route in state.routes {
            guard
                let start = locationsByID[route.fromLocationID],
                let end = locationsByID[route.toLocationID]
            else { continue }
            let presentation = BoardPresentationCatalog.standard.presentation(forRouteID: route.id)
                ?? .init(id: route.id)
            if let spur = presentation.spur,
               let farm = locationsByID[spur.locationID] {
                let anchor = MapNodeFactory.routePoint(
                    t: spur.t,
                    from: start,
                    to: end,
                    in: Self.logicalSize,
                    presentation: presentation
                )
                contentLayer.addChild(MapNodeFactory.brewerySpurNode(
                    routeID: route.id,
                    from: farm,
                    to: anchor,
                    in: Self.logicalSize
                ))
            }
            contentLayer.addChild(
                MapNodeFactory.routeNode(
                    for: route,
                    from: start,
                    to: end,
                    in: Self.logicalSize,
                    presentation: presentation,
                    currentEra: currentEra,
                    isHighlighted: highlightedIDs.contains(route.id)
                )
            )
        }

        for location in state.locations {
            contentLayer.addChild(
                MapNodeFactory.locationNode(
                    for: location,
                    in: Self.logicalSize,
                    isHighlighted: highlightedIDs.contains(location.id),
                    highlightedMerchantIDs: highlightedIDs
                )
            )
        }
        MapNodeFactory.applyInteractionMetrics(to: contentLayer, metrics: viewportMetrics)
    }

    @discardableResult
    func updateViewport(
        size: CGSize,
        insets: MapViewportInsets = .zero
    ) -> CGPoint {
        viewportMetrics = MapViewportMetrics(
            logicalSize: Self.logicalSize,
            viewportSize: size,
            semanticZoom: semanticZoom,
            viewportInsets: insets
        )
        return applyCameraState()
    }

    @discardableResult
    func updateCamera(scale: CGFloat, translation: CGPoint) -> CGPoint {
        semanticZoom = min(
            max(scale, viewportMetrics.zoomFloor),
            MapViewportMetrics.maximumZoom
        )
        self.translation = translation
        viewportMetrics = MapViewportMetrics(
            logicalSize: Self.logicalSize,
            viewportSize: viewportMetrics.viewportSize,
            semanticZoom: semanticZoom,
            viewportInsets: viewportMetrics.viewportInsets
        )
        return applyCameraState()
    }

    static func targetID(fromNodeName name: String?) -> String? {
        guard let name else { return nil }
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              ["location", "route", "merchant"].contains(parts[0]),
              !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    func targetID(atScenePoint point: CGPoint) -> String? {
        for hitNode in nodes(at: point) {
            var candidate: SKNode? = hitNode
            while let node = candidate {
                if let targetID = Self.targetID(fromNodeName: node.name) {
                    return targetID
                }
                candidate = node.parent
            }
        }
        return nil
    }

    @discardableResult
    func activateTarget(atViewPoint point: CGPoint) -> Bool {
        guard
            view != nil,
            let targetID = targetID(atScenePoint: convertPoint(fromView: point))
        else { return false }
        onTargetTap?(targetID)
        return true
    }

    @discardableResult
    private func applyCameraState() -> CGPoint {
        mapCamera.setScale(viewportMetrics.cameraScale)
        let center = CGPoint(x: Self.logicalSize.width / 2, y: Self.logicalSize.height / 2)
        mapCamera.position = viewportMetrics.clampedCameraCenter(
            CGPoint(x: center.x + translation.x, y: center.y + translation.y)
        )
        translation = CGPoint(
            x: mapCamera.position.x - center.x,
            y: mapCamera.position.y - center.y
        )
        MapNodeFactory.applyInteractionMetrics(to: contentLayer, metrics: viewportMetrics)
        return translation
    }
}
