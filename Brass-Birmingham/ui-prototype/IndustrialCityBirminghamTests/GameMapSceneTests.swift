import CoreGraphics
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
        let route = try #require(scene.childNode(withName: "//route:\(state.routes[0].id)") as? SKShapeNode)
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

        let highlighted = try #require(scene.childNode(withName: "//route:\(highlightedID)") as? SKShapeNode)
        let plain = try #require(scene.childNode(withName: "//route:\(plainID)") as? SKShapeNode)
        #expect(highlighted.glowWidth > 0)
        #expect(plain.glowWidth == 0)
        #expect(highlighted.lineWidth > plain.lineWidth)
        #expect(highlighted.childNode(withName: "route-label") != nil)
        #expect(plain.childNode(withName: "route-label") == nil)
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
            let route = try #require(scene.childNode(withName: "//route:\(routeID)") as? SKShapeNode)
            let routeHit = try #require(route.childNode(withName: "route-hit-area") as? SKShapeNode)
            let metrics = scene.viewportMetrics

            let locationDiameterInPoints = locationHit.frame.width * location.xScale / metrics.sceneUnitsPerPoint
            let routeWidthInPoints = routeHit.lineWidth / metrics.sceneUnitsPerPoint
            #expect(locationDiameterInPoints >= 44)
            #expect(routeWidthInPoints >= 44)
            #expect(location.glowWidth > 0)
            #expect(route.glowWidth > 0)
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
        let start = MapNodeFactory.point(for: routeStart, in: GameMapScene.logicalSize)
        let end = MapNodeFactory.point(for: routeEnd, in: GameMapScene.logicalSize)
        let routePoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)

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
}
