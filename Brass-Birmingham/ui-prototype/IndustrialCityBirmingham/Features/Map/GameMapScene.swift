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
    static let minimumZoom: CGFloat = 0.75
    static let maximumZoom: CGFloat = 2.8

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
        self.semanticZoom = min(max(semanticZoom, Self.minimumZoom), Self.maximumZoom)
        self.viewportInsets = viewportInsets.clamped(to: self.viewportSize)
    }

    var aspectFillPointsPerSceneUnit: CGFloat {
        max(viewportSize.width / logicalSize.width, viewportSize.height / logicalSize.height)
    }

    var cameraScale: CGFloat {
        Self.minimumZoom / semanticZoom
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
        CGRect(
            x: viewportInsets.leading,
            y: viewportInsets.top,
            width: max(
                viewportSize.width - viewportInsets.leading - viewportInsets.trailing,
                1
            ),
            height: max(
                viewportSize.height - viewportInsets.top - viewportInsets.bottom,
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
        semanticZoom: MapViewportMetrics.minimumZoom
    )

    private let mapCamera = SKCameraNode()
    private let contentLayer = SKNode()
    private var semanticZoom = MapViewportMetrics.minimumZoom
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
                    highlightedMerchantIDs: highlightedIDs,
                    highlightedIndustryIDs: highlightedIDs
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
            max(scale, MapViewportMetrics.minimumZoom),
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
              ["location", "route", "merchant", "industry"].contains(parts[0]),
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
