import CoreGraphics
import Foundation
import SpriteKit
import Testing
@testable import IndustrialCityBirmingham

@MainActor
struct GameMapSceneTests {
    @Test func configureCreatesEveryLocationNode() {
        let state = DemoFixture.match(playerCount: 4)
        let scene = GameMapScene()

        scene.configure(state: state, highlightedIDs: [])

        for location in state.locations {
            let node = scene.childNode(withName: "//location:\(location.id)")
            #expect(node != nil)
            #expect(node?.childNode(withName: "location-label") != nil)
        }
    }

    @Test func configureCreatesEveryRouteNode() {
        let state = DemoFixture.match(playerCount: 4)
        let scene = GameMapScene()

        scene.configure(state: state, highlightedIDs: [])

        for route in state.routes {
            #expect(scene.childNode(withName: "//route:\(route.id)") != nil)
        }
    }

    @Test func topOriginLocationsConvertToCorrectSpriteKitVerticalOrder() throws {
        let locations = BoardPresentationCatalog.standard.locations
        let stoke = try #require(locations.first { $0.id == "stoke-on-trent" })
        let worcester = try #require(locations.first { $0.id == "worcester" })

        let stokePoint = MapNodeFactory.point(for: stoke, in: GameMapScene.logicalSize)
        let worcesterPoint = MapNodeFactory.point(for: worcester, in: GameMapScene.logicalSize)

        #expect(stokePoint.y > worcesterPoint.y)
    }

    @Test func routePathUsesCalibratedCurveAndCorrectEndpoints() throws {
        let state = DemoFixture.match(playerCount: 4)
        let route = try #require(state.routes.first { $0.id == "birmingham-worcester" })
        let start = try #require(state.locations.first { $0.id == route.fromLocationID })
        let end = try #require(state.locations.first { $0.id == route.toLocationID })
        let presentation = try #require(
            BoardPresentationCatalog.standard.presentation(forRouteID: route.id)
        )

        let path = MapNodeFactory.routePath(
            from: start, to: end, in: GameMapScene.logicalSize, presentation: presentation
        )
        var elementTypes: [CGPathElementType] = []
        path.applyWithBlock { elementTypes.append($0.pointee.type) }

        #expect(elementTypes.contains(.addCurveToPoint))
        #expect(path.currentPoint == MapNodeFactory.point(for: end, in: GameMapScene.logicalSize))
    }

    @Test func configureCreatesNonTargetSouthernBrewerySpur() {
        var state = DemoFixture.match(playerCount: 4)
        state.locations = BoardPresentationCatalog.standard.locations
        state.routes = [
            .init(
                id: "kidderminster-worcester",
                fromLocationID: "kidderminster",
                toLocationID: "worcester"
            )
        ]
        let scene = GameMapScene()
        scene.configure(state: state, highlightedIDs: [])

        #expect(scene.childNode(withName: "//decoration:spur:kidderminster-worcester") != nil)
        #expect(GameMapScene.targetID(fromNodeName: "decoration:spur:kidderminster-worcester") == nil)
    }

    @Test func longChineseLocationNameUsesCompleteTextAcrossAtMostTwoLines() throws {
        let location = try #require(
            BoardPresentationCatalog.standard.locations.first { $0.id == "stoke-on-trent" }
        )
        let marker = MapNodeFactory.locationNode(
            for: location,
            in: GameMapScene.logicalSize,
            isHighlighted: false
        )
        let badge = try #require(marker.childNode(withName: "location-label"))
        let lines = badge.children.compactMap { ($0 as? SKLabelNode)?.text }

        #expect(lines.count == 2)
        #expect(lines.joined() == location.name)
        #expect(lines.allSatisfy { $0.contains("…") == false })
    }

    @Test func configureRendersPublicIndustryAndOwnedLinkMarkers() throws {
        var state = DemoFixture.match(playerCount: 4)
        let locationID = try #require(state.locations.first?.id)
        state.locations[0].industryPlacements = [.init(
            placementID: "placed-cotton", ownerID: "player-amber", tileID: "cotton-1",
            kind: .cotton, level: 1, resourceCount: 2, isFlipped: true, ownerColor: .amber
        )]
        state.routes[0].placedLink = .init(ownerID: "player-crimson", ownerColor: .crimson, era: .rail)
        let scene = GameMapScene()
        scene.configure(state: state, highlightedIDs: [])

        #expect(scene.childNode(withName: "//location:\(locationID)/industry:placed-cotton") != nil)
        let route = try #require(scene.childNode(withName: "//route:\(state.routes[0].id)"))
        #expect(route.userData?["ownerID"] as? String == "player-crimson")
        #expect(route.userData?["era"] as? String == "rail")
    }

    @Test(arguments: [
        ("location:birmingham", "birmingham"),
        ("route:birmingham-coventry", "birmingham-coventry")
    ])
    func targetParserAcceptsKnownKinds(name: String, expectedID: String) {
        #expect(GameMapScene.targetID(fromNodeName: name) == expectedID)
    }

    @Test(arguments: [nil, "", "unknown:birmingham", "location:", "route:"] as [String?])
    func targetParserRejectsInvalidNames(_ name: String?) {
        #expect(GameMapScene.targetID(fromNodeName: name) == nil)
    }

    @Test func highlightedLocationUsesGlowAndNonHighlightedLocationDoesNot() throws {
        let state = DemoFixture.match(playerCount: 4)
        let highlightedID = try #require(state.locations.first?.id)
        let plainID = try #require(state.locations.dropFirst().first?.id)
        let scene = GameMapScene()

        scene.configure(state: state, highlightedIDs: [highlightedID])

        let highlighted = try #require(scene.childNode(withName: "//location:\(highlightedID)") as? SKShapeNode)
        let plain = try #require(scene.childNode(withName: "//location:\(plainID)") as? SKShapeNode)
        #expect(highlighted.glowWidth > 0)
        #expect(plain.glowWidth == 0)
        #expect(highlighted.lineWidth > plain.lineWidth)
    }

    @Test func highlightedRouteUsesGlowAndNonHighlightedRouteDoesNot() throws {
        let state = DemoFixture.match(playerCount: 4)
        let highlightedID = try #require(state.routes.first?.id)
        let plainID = try #require(state.routes.dropFirst().first?.id)
        let scene = GameMapScene()

        scene.configure(state: state, highlightedIDs: [highlightedID])

        let highlighted = try #require(scene.childNode(withName: "//route:\(highlightedID)"))
        let plain = try #require(scene.childNode(withName: "//route:\(plainID)"))
        let highlight = try #require(
            highlighted.childNode(withName: "route-highlight") as? SKShapeNode
        )
        #expect(highlight.glowWidth > 0)
        #expect(highlight.lineWidth > 0)
        #expect(plain.childNode(withName: "route-highlight") == nil)
        #expect(highlighted.childNode(withName: "route-label") != nil)
        #expect(plain.childNode(withName: "route-label") == nil)
    }

    @Test func configureRendersEraLayersAndDimsOnlyUnavailableUnbuiltRoutes() throws {
        var state = DemoFixture.match(playerCount: 4, era: "运河时代")
        state.locations = BoardPresentationCatalog.standard.locations
        state.routes = try BoardPresentationCatalog.standard.routes(for: bundledBoard())
        let scene = GameMapScene()

        scene.configure(state: state, highlightedIDs: [])

        let canal = try #require(scene.childNode(withName: "//route:burton-on-trent-walsall"))
        let rail = try #require(scene.childNode(withName: "//route:belper-leek"))
        let both = try #require(scene.childNode(withName: "//route:birmingham-coventry"))
        #expect(canal.childNode(withName: "route-era-canal") != nil)
        #expect(canal.childNode(withName: "route-era-rail") == nil)
        #expect(rail.childNode(withName: "route-era-rail") != nil)
        #expect(rail.alpha == 0.25)
        #expect(both.childNode(withName: "route-era-canal") != nil)
        #expect(both.childNode(withName: "route-era-rail") != nil)
        #expect(both.alpha == 1)
    }

    @Test func placedAndHighlightedRouteKeepsOwnerEraAndGlowLayers() throws {
        var state = DemoFixture.match(playerCount: 4, era: "铁路时代")
        state.locations = BoardPresentationCatalog.standard.locations
        state.routes = try BoardPresentationCatalog.standard.routes(for: bundledBoard())
        let index = try #require(state.routes.firstIndex { $0.id == "burton-on-trent-walsall" })
        state.routes[index].placedLink = .init(
            ownerID: "player-crimson", ownerColor: .crimson, era: .canal
        )
        let scene = GameMapScene()

        scene.configure(state: state, highlightedIDs: ["burton-on-trent-walsall"])

        let route = try #require(scene.childNode(withName: "//route:burton-on-trent-walsall"))
        #expect(route.alpha == 1)
        #expect(route.childNode(withName: "route-highlight") != nil)
        #expect(route.childNode(withName: "route-era-canal") != nil)
        #expect(route.childNode(withName: "route-owner") != nil)
        #expect(route.childNode(withName: "route-label") != nil)
        #expect(route.userData?["ownerID"] as? String == "player-crimson")
    }

    @Test func railOnlyCurvedRouteUsesMultipleDashedPathSegments() throws {
        var state = DemoFixture.match(playerCount: 4, era: "铁路时代")
        state.locations = BoardPresentationCatalog.standard.locations
        state.routes = try BoardPresentationCatalog.standard.routes(for: bundledBoard())
        let scene = GameMapScene()
        scene.configure(state: state, highlightedIDs: [])

        let route = try #require(scene.childNode(withName: "//route:belper-leek"))
        let rail = try #require(route.childNode(withName: "route-era-rail") as? SKShapeNode)
        let path = try #require(rail.path)
        var moveCount = 0
        var lineCount = 0
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { moveCount += 1 }
            if element.pointee.type == .addLineToPoint { lineCount += 1 }
        }
        #expect(moveCount > 1)
        #expect(lineCount > 1)
    }

    @Test func cameraUsesAspectFillAndSemanticZoomMapsInversely() throws {
        let scene = GameMapScene()
        let camera = try #require(scene.camera)

        #expect(scene.scaleMode == .aspectFill)
        scene.updateViewport(size: CGSize(width: 852, height: 393))
        scene.updateCamera(scale: MapViewportMetrics.minimumZoom, translation: .zero)
        #expect(abs(camera.xScale - 1) < 0.0001)

        scene.updateCamera(scale: MapViewportMetrics.maximumZoom, translation: .zero)
        #expect(camera.xScale < 1)
        #expect(abs(camera.xScale - (MapViewportMetrics.minimumZoom / MapViewportMetrics.maximumZoom)) < 0.0001)
    }

    @Test func semanticZoomClampsAtBothBounds() throws {
        let scene = GameMapScene()
        let camera = try #require(scene.camera)

        scene.updateCamera(scale: 0.1, translation: .zero)
        #expect(abs(camera.xScale - 1) < 0.0001)

        scene.updateCamera(scale: 9, translation: .zero)
        #expect(abs(camera.xScale - (MapViewportMetrics.minimumZoom / MapViewportMetrics.maximumZoom)) < 0.0001)
    }

    @Test func dragPointsConvertToSceneOffsetThatFollowsTheFinger() {
        let metrics = MapViewportMetrics(
            logicalSize: GameMapScene.logicalSize,
            viewportSize: CGSize(width: 852, height: 393),
            semanticZoom: 1
        )

        let offset = metrics.sceneTranslation(forDrag: CGSize(width: 100, height: 50))

        #expect(offset.x < 0)
        #expect(offset.y > 0)
        #expect(abs(offset.x + 100 * metrics.sceneUnitsPerPoint) < 0.0001)
        #expect(abs(offset.y - 50 * metrics.sceneUnitsPerPoint) < 0.0001)
    }

    @Test(arguments: [
        CGSize(width: 667, height: 375),
        CGSize(width: 852, height: 393),
        CGSize(width: 932, height: 430),
        CGSize(width: 1_024, height: 768),
        CGSize(width: 1_194, height: 834),
        CGSize(width: 1_366, height: 1_024)
    ])
    func hitGeometryRemainsAtLeast44PointsAcrossViewports(_ viewport: CGSize) throws {
        for semanticZoom in [MapViewportMetrics.minimumZoom, MapViewportMetrics.maximumZoom] {
            let state = DemoFixture.match(playerCount: 4)
            let locationID = try #require(state.locations.first?.id)
            let routeID = try #require(state.routes.first?.id)
            let scene = GameMapScene()
            scene.configure(state: state, highlightedIDs: [locationID, routeID])
            scene.updateViewport(size: viewport)
            scene.updateCamera(scale: semanticZoom, translation: .zero)

            let location = try #require(scene.childNode(withName: "//location:\(locationID)") as? SKShapeNode)
            let locationHit = try #require(location.childNode(withName: "location-hit-area") as? SKShapeNode)
            let route = try #require(scene.childNode(withName: "//route:\(routeID)"))
            let routeHit = try #require(route.childNode(withName: "route-hit-area") as? SKShapeNode)
            let routeHighlight = try #require(
                route.childNode(withName: "route-highlight") as? SKShapeNode
            )
            let metrics = scene.viewportMetrics

            let locationDiameterInPoints = locationHit.frame.width * location.xScale / metrics.sceneUnitsPerPoint
            let routeWidthInPoints = routeHit.lineWidth / metrics.sceneUnitsPerPoint
            #expect(locationDiameterInPoints >= 44)
            #expect(routeWidthInPoints >= 44)
            #expect(location.glowWidth > 0)
            #expect(routeHighlight.glowWidth > 0)
        }
    }

    @Test(arguments: [
        CGSize(width: 667, height: 375),
        CGSize(width: 852, height: 393),
        CGSize(width: 932, height: 430),
        CGSize(width: 1_024, height: 768),
        CGSize(width: 1_194, height: 834),
        CGSize(width: 1_366, height: 1_024)
    ])
    func extremeTranslationKeepsVisibleRectInsideMap(_ viewport: CGSize) throws {
        for semanticZoom in [MapViewportMetrics.minimumZoom, MapViewportMetrics.maximumZoom] {
            let scene = GameMapScene()
            let camera = try #require(scene.camera)
            scene.updateViewport(size: viewport)
            scene.updateCamera(
                scale: semanticZoom,
                translation: CGPoint(x: 100_000, y: -100_000)
            )

            let visibleSize = scene.viewportMetrics.visibleSceneSize
            let visibleRect = CGRect(
                x: camera.position.x - visibleSize.width / 2,
                y: camera.position.y - visibleSize.height / 2,
                width: visibleSize.width,
                height: visibleSize.height
            )
            #expect(visibleRect.minX >= -0.0001)
            #expect(visibleRect.minY >= -0.0001)
            #expect(visibleRect.maxX <= GameMapScene.logicalSize.width + 0.0001)
            #expect(visibleRect.maxY <= GameMapScene.logicalSize.height + 0.0001)
        }
    }

    @Test func viewportResizeRecomputesCameraBounds() throws {
        let scene = GameMapScene()
        let camera = try #require(scene.camera)
        scene.updateViewport(size: CGSize(width: 667, height: 375))
        scene.updateCamera(
            scale: MapViewportMetrics.minimumZoom,
            translation: CGPoint(x: .zero, y: 100_000)
        )
        let phonePosition = camera.position

        scene.updateViewport(size: CGSize(width: 1_366, height: 1_024))

        #expect(camera.position != phonePosition)
        #expect(scene.viewportMetrics.viewportSize == CGSize(width: 1_366, height: 1_024))
    }

    @Test func targetLookupFindsLocationAndRouteAtScenePoints() throws {
        let state = DemoFixture.match(playerCount: 4)
        let location = try #require(state.locations.first)
        let route = try #require(state.routes.first)
        let routeStart = try #require(state.locations.first { $0.id == route.fromLocationID })
        let routeEnd = try #require(state.locations.first { $0.id == route.toLocationID })
        let scene = GameMapScene()
        scene.configure(state: state, highlightedIDs: [])

        let locationPoint = MapNodeFactory.point(for: location, in: GameMapScene.logicalSize)
        let presentation = BoardPresentationCatalog.standard.presentation(forRouteID: route.id)
            ?? .init(id: route.id)
        let routePoint = MapNodeFactory.routePoint(
            t: 0.5,
            from: routeStart,
            to: routeEnd,
            in: GameMapScene.logicalSize,
            presentation: presentation
        )

        #expect(scene.targetID(atScenePoint: locationPoint) == location.id)
        #expect(scene.targetID(atScenePoint: routePoint) == route.id)
    }

    @Test func overscrollReturnsCanonicalOffsetAndReverseDragMovesImmediately() throws {
        let scene = GameMapScene()
        let camera = try #require(scene.camera)
        scene.updateViewport(size: CGSize(width: 852, height: 393))

        let appliedAtEdge = scene.updateCamera(
            scale: MapViewportMetrics.maximumZoom,
            translation: CGPoint(x: 100_000, y: 0)
        )
        let cameraAtEdge = camera.position
        let reversed = scene.updateCamera(
            scale: MapViewportMetrics.maximumZoom,
            translation: CGPoint(x: appliedAtEdge.x - 10, y: appliedAtEdge.y)
        )

        #expect(appliedAtEdge.x.isFinite)
        #expect(abs(appliedAtEdge.x) < 100_000)
        #expect(reversed.x == appliedAtEdge.x - 10)
        #expect(camera.position.x == cameraAtEdge.x - 10)
    }

    @Test func unpannableAxisDoesNotRevealLatentOffsetAfterZoomIn() throws {
        let scene = GameMapScene()
        let camera = try #require(scene.camera)
        scene.updateViewport(size: CGSize(width: 852, height: 393))

        let appliedAtMinimumZoom = scene.updateCamera(
            scale: MapViewportMetrics.minimumZoom,
            translation: CGPoint(x: 10_000, y: 0)
        )
        let appliedAtMaximumZoom = scene.updateCamera(
            scale: MapViewportMetrics.maximumZoom,
            translation: appliedAtMinimumZoom
        )

        #expect(appliedAtMinimumZoom.x == 0)
        #expect(appliedAtMaximumZoom.x == 0)
        #expect(camera.position.x == GameMapScene.logicalSize.width / 2)
    }

    @Test func viewportResizeReturnsCanonicalOffsetForNewBounds() {
        let scene = GameMapScene()
        scene.updateViewport(size: CGSize(width: 667, height: 375))
        let phoneOffset = scene.updateCamera(
            scale: MapViewportMetrics.minimumZoom,
            translation: CGPoint(x: 0, y: 100_000)
        )

        let resizedOffset = scene.updateViewport(size: CGSize(width: 1_366, height: 1_024))

        #expect(phoneOffset.y > 0)
        #expect(resizedOffset == .zero)
    }

    @Test func viewportInsetsClampToANonemptyInteractiveRect() {
        let metrics = MapViewportMetrics(
            logicalSize: GameMapScene.logicalSize,
            viewportSize: CGSize(width: 200, height: 100),
            semanticZoom: MapViewportMetrics.minimumZoom,
            viewportInsets: .init(top: -10, leading: 500, bottom: 500, trailing: -4)
        )

        #expect(metrics.viewportInsets.top == 0)
        #expect(metrics.viewportInsets.trailing == 0)
        #expect(metrics.unobscuredViewportRect.width >= 1)
        #expect(metrics.unobscuredViewportRect.height >= 1)
    }

    @Test func bottomEdgeCanReachAbovePhoneHandAtMinimumZoom() throws {
        let insets = MapViewportInsets(top: 76, leading: 44, bottom: 92, trailing: 44)
        let state = DemoFixture.match(playerCount: 4)
        let gloucester = try #require(state.locations.first { $0.id == "gloucester" })
        let scene = GameMapScene()
        let camera = try #require(scene.camera)
        scene.updateViewport(size: CGSize(width: 852, height: 393), insets: insets)
        scene.configure(state: state, highlightedIDs: [gloucester.id])

        scene.updateCamera(
            scale: MapViewportMetrics.minimumZoom,
            translation: CGPoint(x: 0, y: -100_000)
        )

        let clearRect = scene.viewportMetrics.unobscuredSceneRect(cameraCenter: camera.position)
        let gloucesterPoint = MapNodeFactory.point(for: gloucester, in: GameMapScene.logicalSize)
        #expect(abs(clearRect.minY) < 0.0001)
        #expect(camera.position.y < GameMapScene.logicalSize.height / 2)
        #expect(clearRect.contains(gloucesterPoint))
        #expect(scene.targetID(atScenePoint: gloucesterPoint) == gloucester.id)
    }

    @Test func zeroInsetsPreserveLegacyCameraBounds() {
        let legacy = MapViewportMetrics(
            logicalSize: GameMapScene.logicalSize,
            viewportSize: CGSize(width: 852, height: 393),
            semanticZoom: 1
        )
        let explicitZero = MapViewportMetrics(
            logicalSize: GameMapScene.logicalSize,
            viewportSize: CGSize(width: 852, height: 393),
            semanticZoom: 1,
            viewportInsets: .zero
        )

        #expect(legacy == explicitZero)
        #expect(
            legacy.clampedCameraCenter(CGPoint(x: -10_000, y: 10_000))
                == explicitZero.clampedCameraCenter(CGPoint(x: -10_000, y: 10_000))
        )
    }

    @Test func routeEraStyleClassifiesAllThreeAllowedEraShapes() {
        #expect(MapRouteEraStyle.resolve(
            route: route(eras: [.canal]), currentEra: .canal
        ).kind == .canalOnly)
        #expect(MapRouteEraStyle.resolve(
            route: route(eras: [.rail]), currentEra: .rail
        ).kind == .railOnly)
        #expect(MapRouteEraStyle.resolve(
            route: route(eras: [.canal, .rail]), currentEra: .canal
        ).kind == .both)
    }

    @Test func unavailableUnbuiltRouteDimsButBuiltAndUnknownEraRoutesDoNot() {
        #expect(MapRouteEraStyle.resolve(
            route: route(eras: [.rail]), currentEra: .canal
        ).opacity == 0.25)
        #expect(MapRouteEraStyle.resolve(
            route: route(eras: [.rail], placed: true), currentEra: .canal
        ).opacity == 1)
        #expect(MapRouteEraStyle.resolve(
            route: route(eras: [.rail]), currentEra: nil
        ).opacity == 1)
    }

    @Test func visibleMatchEraMapsToPresentationEra() {
        #expect(MapRouteEraStyle.currentEra(from: "运河时代") == .canal)
        #expect(MapRouteEraStyle.currentEra(from: "铁路时代") == .rail)
        #expect(MapRouteEraStyle.currentEra(from: "unknown") == nil)
    }

    @Test func routeAccessibilityExplainsTypeAvailabilityAndPlacedOwner() {
        let unavailable = MapRoute(
            id: "rail", fromLocationID: "a", toLocationID: "b",
            availableEras: [.rail]
        )
        #expect(MapRouteAccessibility.label(
            route: unavailable, startName: "伯明翰", endName: "雷迪奇",
            currentEra: .canal, ownerName: nil
        ) == "伯明翰至雷迪奇，铁路专用，当前时代不可修")

        let placed = MapRoute(
            id: "canal", fromLocationID: "a", toLocationID: "b",
            availableEras: [.canal],
            placedLink: .init(ownerID: "p1", ownerColor: .amber, era: .canal)
        )
        #expect(MapRouteAccessibility.label(
            route: placed, startName: "伯顿", endName: "沃尔索尔",
            currentEra: .rail, ownerName: "Owen"
        ) == "伯顿至沃尔索尔，运河专用，Owen 已建运河")
    }

    private func route(
        eras: [MapPlacedLink.Era], placed: Bool = false
    ) -> MapRoute {
        let placedLink: MapPlacedLink?
        if placed {
            guard let era = eras.first else {
                preconditionFailure("A placed test route requires an available era")
            }
            placedLink = .init(ownerID: "owner", ownerColor: .amber, era: era)
        } else {
            placedLink = nil
        }

        return MapRoute(
            id: "test-route", fromLocationID: "a", toLocationID: "b",
            availableEras: eras, placedLink: placedLink
        )
    }

    private func bundledBoard() throws -> GameCore.BoardDefinition {
        let url = try #require(Bundle.main.url(forResource: "map", withExtension: "json"))
        return try JSONDecoder().decode(GameCore.BoardDefinition.self, from: Data(contentsOf: url))
    }
}
