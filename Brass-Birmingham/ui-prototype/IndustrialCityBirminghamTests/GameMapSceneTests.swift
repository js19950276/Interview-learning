import CoreGraphics
import Foundation
import SpriteKit
import Testing
@testable import IndustrialCityBirmingham

@MainActor
struct GameMapSceneTests {
    @Test func accessibilityActivationConsumesPairedPhysicalTapInEitherCallbackOrder() {
        var physicalFirst = MapTapRoutingState()
        physicalFirst.recordPhysicalTap(.background)
        physicalFirst.recordAccessibilityActivation()
        #expect(physicalFirst.resolve() == nil)

        var accessibilityFirst = MapTapRoutingState()
        accessibilityFirst.recordAccessibilityActivation()
        accessibilityFirst.recordPhysicalTap(.target("birmingham"))
        #expect(accessibilityFirst.resolve() == nil)
    }

    @Test func unpairedPhysicalTapPreservesTargetAndBackgroundRouting() {
        var target = MapTapRoutingState()
        target.recordPhysicalTap(.target("birmingham"))
        #expect(target.resolve() == .target("birmingham"))

        var background = MapTapRoutingState()
        background.recordPhysicalTap(.background)
        #expect(background.resolve() == .background)
    }

    @Test func configureCreatesEveryLocationNode() {
        let state = DemoFixture.match(playerCount: 4)
        let scene = GameMapScene()

        scene.configure(state: state, highlightedIDs: ["placed-coal"])

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
            placementID: "placed-coal", ownerID: "player-amber", tileID: "coal-1",
            kind: .coal, level: 1, resourceCount: 2, isFlipped: true, ownerColor: .amber
        )]
        state.routes[0].placedLink = .init(ownerID: "player-crimson", ownerColor: .crimson, era: .rail)
        let scene = GameMapScene()
        scene.configure(state: state, highlightedIDs: ["placed-coal"])

        let industry = try #require(
            scene.childNode(withName: "//location:\(locationID)/industry:placed-coal")
        )
        let medallion = try #require(industry.childNode(withName: "industry-medallion") as? SKSpriteNode)
        let ownerStrip = try #require(industry.childNode(withName: "industry-owner-strip") as? SKShapeNode)
        let detailLabel = try #require(industry.childNode(withName: "industry-detail") as? SKLabelNode)
        #expect(industry.childNode(withName: "industry-kind") == nil)
        #expect(medallion.userData?["assetName"] as? String == IndustrialMatchAsset.coal.name)
        #expect(medallion.isUserInteractionEnabled == false)
        #expect(ownerStrip.isUserInteractionEnabled == false)
        #expect(detailLabel.text == "L1·2")
        #expect(industry.userData?["industryKind"] as? String == IndustryKind.coal.rawValue)
        #expect(industry.userData?["industryName"] as? String == "煤矿")
        #expect(industry.userData?["isHighlighted"] as? Bool == true)
        #expect(industry.childNode(withName: "industry-legal-glow") != nil)
        let route = try #require(scene.childNode(withName: "//route:\(state.routes[0].id)"))
        #expect(route.userData?["ownerID"] as? String == "player-crimson")
        #expect(route.userData?["era"] as? String == "rail")
    }

    @Test func configureRendersCenteredMerchantCardsWithStableSemantics() throws {
        var state = DemoFixture.match(playerCount: 4)
        let locationID = try #require(state.locations.first?.id)
        state.locations[0].merchantPlacements = [
            .init(
                slotID: "merchant-blank", acceptedIndustries: [], hasBeer: false,
                bonusKind: .victoryPoints, bonusAmount: 4
            ),
            .init(
                slotID: "merchant-any",
                acceptedIndustries: [.cotton, .manufacturer, .pottery], hasBeer: true,
                bonusKind: .develop, bonusAmount: 1
            ),
            .init(
                slotID: "merchant-cotton", acceptedIndustries: [.cotton], hasBeer: true,
                bonusKind: .income, bonusAmount: 2
            ),
            .init(
                slotID: "merchant-manufacturer", acceptedIndustries: [.manufacturer], hasBeer: false,
                bonusKind: .money, bonusAmount: 5
            ),
            .init(
                slotID: "merchant-pottery", acceptedIndustries: [.pottery], hasBeer: true,
                bonusKind: .victoryPoints, bonusAmount: 3
            ),
        ]
        let scene = GameMapScene()

        scene.configure(state: state, highlightedIDs: [])

        let marker = try #require(scene.childNode(withName: "//location:\(locationID)"))
        let expectations: [(String, String, String, String)] = [
            ("merchant-blank", "空", "—", "+4VP"),
            ("merchant-any", "任", "酒", "开发1"),
            ("merchant-cotton", "棉", "酒", "收入2"),
            ("merchant-manufacturer", "制", "—", "£5"),
            ("merchant-pottery", "陶", "酒", "+3VP"),
        ]
        let merchants = try expectations.map { slotID, acceptance, beer, bonus in
            let merchant = try #require(
                marker.childNode(withName: "merchant:\(slotID)") as? SKShapeNode
            )
            #expect(
                (merchant.childNode(withName: "merchant-acceptance") as? SKLabelNode)?.text
                    == acceptance
            )
            #expect(
                (merchant.childNode(withName: "merchant-beer") as? SKLabelNode)?.text == beer
            )
            #expect(
                (merchant.childNode(withName: "merchant-bonus") as? SKLabelNode)?.text == bonus
            )
            #expect(merchant.userData?["slotID"] as? String == slotID)
            #expect(merchant.userData?["hasBeer"] as? Bool == (beer == "酒"))
            #expect(merchant.userData?["bonusAmount"] as? Int == Int(bonus.filter(\.isNumber)))
            #expect(merchant.userData?["isHighlighted"] as? Bool == false)
            return merchant
        }
        #expect(merchants.map(\.position.x) == [-84, -42, 0, 42, 84])
        #expect(
            merchants[1].userData?["acceptedIndustryIDs"] as? [String]
                == [IndustryKind.cotton, .manufacturer, .pottery].map(\.rawValue)
        )
        #expect(
            merchants[1].userData?["bonusKind"] as? String == MerchantBonusKind.develop.rawValue
        )
    }

    @Test func highlightedMerchantUsesLegalGlowAndVisualStateWithoutChangingTargets() throws {
        var state = DemoFixture.match(playerCount: 4)
        state.locations[0].merchantPlacements = [
            .init(
                slotID: "merchant-plain", acceptedIndustries: [.cotton], hasBeer: true,
                bonusKind: .income, bonusAmount: 2
            ),
            .init(
                slotID: "merchant-highlighted", acceptedIndustries: [.pottery], hasBeer: false,
                bonusKind: .money, bonusAmount: 5
            ),
        ]
        let scene = GameMapScene()

        scene.configure(state: state, highlightedIDs: ["merchant-highlighted"])

        let plain = try #require(
            scene.childNode(withName: "//merchant:merchant-plain") as? SKShapeNode
        )
        let highlighted = try #require(
            scene.childNode(withName: "//merchant:merchant-highlighted") as? SKShapeNode
        )
        let glow = try #require(highlighted.childNode(withName: "merchant-legal-glow") as? SKShapeNode)
        #expect(plain.childNode(withName: "merchant-legal-glow") == nil)
        #expect(highlighted.childNode(withName: "merchant-parchment") != nil)
        #expect(plain.childNode(withName: "merchant-parchment") != nil)
        #expect(glow.glowWidth > 0)
        #expect(glow.isUserInteractionEnabled == false)
        expectColor(glow.strokeColor, matches: BrassColor.legalGreen)
        #expect(plain.userData?["isHighlighted"] as? Bool == false)
        #expect(highlighted.userData?["isHighlighted"] as? Bool == true)
        #expect(plain.userData?["visualState"] as? String == "normal")
        #expect(highlighted.userData?["visualState"] as? String == "legal")
        #expect(GameMapScene.targetID(fromNodeName: highlighted.name) == "merchant-highlighted")
    }

    @Test(arguments: [
        ("location:birmingham", "birmingham"),
        ("route:birmingham-coventry", "birmingham-coventry"),
        ("merchant:oxford-1", "oxford-1"),
        ("industry:beer-a", "beer-a")
    ])
    func targetParserAcceptsKnownKinds(name: String, expectedID: String) {
        #expect(GameMapScene.targetID(fromNodeName: name) == expectedID)
    }

    @Test(arguments: [nil, "", "unknown:birmingham", "location:", "route:", "merchant:"] as [String?])
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
        let glow = try #require(highlighted.childNode(withName: "location-legal-glow") as? SKShapeNode)
        #expect(glow.glowWidth > 0)
        #expect(glow.isUserInteractionEnabled == false)
        #expect(plain.childNode(withName: "location-legal-glow") == nil)
        #expect(highlighted.lineWidth > plain.lineWidth)
        #expect(highlighted.userData?["visualState"] as? String == "legal")
        #expect(plain.userData?["visualState"] as? String == "normal")
    }

    @Test func highlightedRouteUsesLegalGlowAndVisualStateWithoutChangingTargets() throws {
        let state = DemoFixture.match(playerCount: 4)
        let highlightedID = try #require(state.routes.first?.id)
        let plainID = try #require(state.routes.dropFirst().first?.id)
        let scene = GameMapScene()

        scene.configure(state: state, highlightedIDs: [highlightedID])

        let highlighted = try #require(scene.childNode(withName: "//route:\(highlightedID)"))
        let plain = try #require(scene.childNode(withName: "//route:\(plainID)"))
        let glow = try #require(
            highlighted.childNode(withName: "route-legal-glow") as? SKShapeNode
        )
        #expect(glow.glowWidth > 0)
        #expect(glow.lineWidth > 0)
        #expect(glow.isUserInteractionEnabled == false)
        expectColor(glow.strokeColor, matches: BrassColor.legalGreen)
        #expect(plain.childNode(withName: "route-legal-glow") == nil)
        #expect(highlighted.childNode(withName: "route-label") != nil)
        #expect(plain.childNode(withName: "route-label") == nil)
        #expect(highlighted.userData?["visualState"] as? String == "legal")
        #expect(plain.userData?["visualState"] as? String == "normal")
        #expect(GameMapScene.targetID(fromNodeName: highlighted.name) == highlightedID)
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
        #expect(route.childNode(withName: "route-legal-glow") != nil)
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
            var state = DemoFixture.match(playerCount: 4)
            let locationID = try #require(state.locations.first?.id)
            let routeID = try #require(state.routes.first?.id)
            let merchantID = "merchant-hit-test"
            state.locations[0].merchantPlacements = [.init(
                slotID: merchantID, acceptedIndustries: [.cotton], hasBeer: true,
                bonusKind: .victoryPoints, bonusAmount: 4
            )]
            let scene = GameMapScene()
            scene.configure(state: state, highlightedIDs: [locationID, routeID, merchantID])
            scene.updateViewport(size: viewport)
            scene.updateCamera(scale: semanticZoom, translation: .zero)

            let location = try #require(scene.childNode(withName: "//location:\(locationID)") as? SKShapeNode)
            let locationHit = try #require(location.childNode(withName: "location-hit-area") as? SKShapeNode)
            let merchant = try #require(
                location.childNode(withName: "merchant:\(merchantID)") as? SKShapeNode
            )
            let merchantHit = try #require(
                merchant.childNode(withName: "merchant-hit-area") as? SKShapeNode
            )
            let route = try #require(scene.childNode(withName: "//route:\(routeID)"))
            let routeHit = try #require(route.childNode(withName: "route-hit-area") as? SKShapeNode)
            let routeGlow = try #require(
                route.childNode(withName: "route-legal-glow") as? SKShapeNode
            )
            let metrics = scene.viewportMetrics

            let locationDiameterInPoints = locationHit.frame.width * location.xScale / metrics.sceneUnitsPerPoint
            let merchantWidthInPoints = merchantHit.frame.width
                * merchant.xScale * location.xScale / metrics.sceneUnitsPerPoint
            let merchantHeightInPoints = merchantHit.frame.height
                * merchant.yScale * location.yScale / metrics.sceneUnitsPerPoint
            let routeWidthInPoints = routeHit.lineWidth / metrics.sceneUnitsPerPoint
            #expect(locationDiameterInPoints >= 44)
            #expect(merchantWidthInPoints >= 44)
            #expect(merchantHeightInPoints >= 44)
            #expect(routeWidthInPoints >= 44)
            #expect(location.childNode(withName: "location-legal-glow") != nil)
            #expect(routeGlow.glowWidth > 0)
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
    func realMarketMerchantCardsStayInsideLogicalBoardAcrossViewports(
        _ viewport: CGSize
    ) throws {
        let state = marketMerchantState()
        let scene = GameMapScene()
        scene.configure(state: state, highlightedIDs: [])

        for semanticZoom in [MapViewportMetrics.minimumZoom, MapViewportMetrics.maximumZoom] {
            scene.updateViewport(size: viewport)
            scene.updateCamera(scale: semanticZoom, translation: .zero)

            for location in state.locations where !location.merchantPlacements.isEmpty {
                for placement in location.merchantPlacements {
                    let merchant = try #require(
                        scene.childNode(withName: "//merchant:\(placement.slotID)")
                    )
                    let frame = sceneFrame(of: merchant, in: scene)
                    #expect(frame.minX >= -0.001)
                    #expect(frame.minY >= -0.001)
                    #expect(frame.maxX <= GameMapScene.logicalSize.width + 0.001)
                    #expect(frame.maxY <= GameMapScene.logicalSize.height + 0.001)
                }
            }
        }
    }

    @Test func bottomMarketCardsAndLabelsStackInwardWithoutOverlap() throws {
        let state = marketMerchantState()
        let scene = GameMapScene()
        scene.configure(state: state, highlightedIDs: [])

        for locationID in ["gloucester", "oxford"] {
            let marker = try #require(
                scene.childNode(withName: "//location:\(locationID)")
            )
            let label = try #require(marker.childNode(withName: "location-label"))
            let merchants = marker.children.filter { $0.name?.hasPrefix("merchant:") == true }
            #expect(merchants.isEmpty == false)
            #expect(merchants.allSatisfy { $0.position.y > 0 })
            #expect(label.frame.minY >= (merchants.map(\.frame.maxY).max() ?? 0))
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

    @Test func targetLookupFindsMerchantWhenPointHitsAChildLabel() throws {
        var state = DemoFixture.match(playerCount: 4)
        state.locations[0].merchantPlacements = [
            .init(
                slotID: "merchant-tappable", acceptedIndustries: [.cotton], hasBeer: true,
                bonusKind: .victoryPoints, bonusAmount: 4
            )
        ]
        let scene = GameMapScene()
        scene.configure(state: state, highlightedIDs: ["merchant-tappable"])
        let acceptance = try #require(
            scene.childNode(withName: "//merchant:merchant-tappable/merchant-acceptance")
        )
        let labelPoint = acceptance.convert(CGPoint.zero, to: scene)

        #expect(scene.targetID(atScenePoint: labelPoint) == "merchant-tappable")
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

    @Test func merchantAccessibilityLabelExplainsMarketAcceptanceBeerAndReward() {
        let merchant = MapMerchantPlacement(
            slotID: "oxford-1",
            acceptedIndustries: [.cotton, .manufacturer, .pottery],
            hasBeer: true,
            bonusKind: .income,
            bonusAmount: 2
        )

        #expect(
            MapMerchantAccessibility.label(locationName: "牛津", merchant: merchant)
                == "牛津，任意制成品，贸易商啤酒可用，收入 +2"
        )
    }

    @Test(arguments: [
        ([IndustryKind.cotton], "棉纺厂"),
        ([IndustryKind.manufacturer], "制造厂"),
        ([IndustryKind.pottery], "陶瓷厂"),
    ])
    func merchantAccessibilityNamesEveryAcceptanceShape(
        acceptedIndustries: [IndustryKind], expectedName: String
    ) {
        let merchant = MapMerchantPlacement(
            slotID: "market-1", acceptedIndustries: acceptedIndustries, hasBeer: false,
            bonusKind: .money, bonusAmount: 5
        )

        #expect(
            MapMerchantAccessibility.label(locationName: "市场", merchant: merchant)
                == "市场，\(expectedName)，贸易商啤酒已用尽，奖励不可用"
        )
    }

    @Test func blankMerchantAccessibilityDoesNotClaimSpentBeer() {
        let merchant = MapMerchantPlacement(
            slotID: "market-blank", acceptedIndustries: [], hasBeer: false,
            bonusKind: .money, bonusAmount: 5
        )

        #expect(
            MapMerchantAccessibility.label(locationName: "市场", merchant: merchant)
                == "市场，空白贸易商，无贸易商啤酒，奖励不可用"
        )
    }

    @Test func accessibleTargetsIncludeOnlyHighlightedMerchantAlongsideLocationAndRoute() throws {
        var state = DemoFixture.match(playerCount: 4)
        let locationID = try #require(state.locations.first?.id)
        let routeID = try #require(state.routes.first?.id)
        state.locations[0].merchantPlacements = [
            .init(
                slotID: "merchant-legal", acceptedIndustries: [.cotton], hasBeer: true,
                bonusKind: .develop, bonusAmount: 1
            ),
            .init(
                slotID: "merchant-not-highlighted", acceptedIndustries: [.pottery], hasBeer: true,
                bonusKind: .victoryPoints, bonusAmount: 4
            ),
        ]

        let targets = GameMapAccessibility.targets(
            state: state,
            highlightedIDs: [locationID, routeID, "merchant-legal"]
        )

        #expect(targets.map(\.id).contains(locationID))
        #expect(targets.map(\.id).contains(routeID))
        #expect(targets.map(\.id).contains("merchant-legal"))
        #expect(targets.map(\.id).contains("merchant-not-highlighted") == false)
        #expect(
            targets.first { $0.id == "merchant-legal" }?.label
                == "\(state.locations[0].name)，棉纺厂，贸易商啤酒可用，开发 +1"
        )
    }

    @Test func accessibleTargetsIncludeEveryHighlightedIndustryWithDistinctChineseLabels() throws {
        var state = DemoFixture.match(playerCount: 4)
        let location = try #require(state.locations.first)
        state.locations[0] = MapLocation(
            id: location.id,
            name: "伯明翰",
            x: location.x,
            y: location.y,
            industryPlacements: [
                .init(
                    placementID: "industry-coal-a", ownerID: "player-amber", tileID: "coal-2-a",
                    kind: .coal, level: 2, resourceCount: 1, isFlipped: false,
                    ownerColor: .amber
                ),
                .init(
                    placementID: "industry-coal-b", ownerID: "player-amber", tileID: "coal-2-b",
                    kind: .coal, level: 2, resourceCount: 0, isFlipped: true,
                    ownerColor: .amber
                ),
                .init(
                    placementID: "industry-iron-hidden", ownerID: "player-crimson",
                    tileID: "iron-1", kind: .iron, level: 1, resourceCount: 4,
                    isFlipped: false, ownerColor: .crimson
                ),
            ],
            merchantPlacements: location.merchantPlacements
        )

        let targets = GameMapAccessibility.targets(
            state: state,
            highlightedIDs: ["industry-coal-a", "industry-coal-b"]
        )

        #expect(targets.map(\.id) == ["industry-coal-a", "industry-coal-b"])
        let first = try #require(targets.first { $0.id == "industry-coal-a" })
        let second = try #require(targets.first { $0.id == "industry-coal-b" })
        #expect(
            first.label
                == "伯明翰，第1个产业，煤矿，等级2，剩余资源1，所有者 Owen"
        )
        #expect(
            second.label
                == "伯明翰，第2个产业，煤矿，等级2，已翻面，所有者 Owen"
        )
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

    private func marketMerchantState() -> DemoMatchState {
        var state = DemoFixture.match(playerCount: 4)
        state.locations = BoardPresentationCatalog.standard.locations
        state.routes = []
        let slotCounts = [
            "shrewsbury": 1,
            "gloucester": 2,
            "oxford": 2,
            "warrington": 2,
            "nottingham": 2,
        ]
        for index in state.locations.indices {
            let locationID = state.locations[index].id
            let count = slotCounts[locationID] ?? 0
            state.locations[index].merchantPlacements = (0..<count).map { slotIndex in
                .init(
                    slotID: "\(locationID)-\(slotIndex + 1)",
                    acceptedIndustries: [.cotton], hasBeer: true,
                    bonusKind: .victoryPoints, bonusAmount: 4
                )
            }
        }
        return state
    }

    private func sceneFrame(of node: SKNode, in scene: SKScene) -> CGRect {
        guard let parent = node.parent else { return .null }
        let frame = node.frame
        let points = [
            CGPoint(x: frame.minX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.minX, y: frame.maxY),
            CGPoint(x: frame.maxX, y: frame.maxY),
        ].map { parent.convert($0, to: scene) }
        let xValues = points.map(\.x)
        let yValues = points.map(\.y)
        return CGRect(
            x: xValues.min() ?? 0,
            y: yValues.min() ?? 0,
            width: (xValues.max() ?? 0) - (xValues.min() ?? 0),
            height: (yValues.max() ?? 0) - (yValues.min() ?? 0)
        )
    }

    private func expectColor(
        _ uiColor: UIColor,
        matches brassColor: BrassColor,
        tolerance: CGFloat = 0.002
    ) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #expect(uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        #expect(abs(red - CGFloat(brassColor.red)) < tolerance)
        #expect(abs(green - CGFloat(brassColor.green)) < tolerance)
        #expect(abs(blue - CGFloat(brassColor.blue)) < tolerance)
    }

    private func bundledBoard() throws -> GameCore.BoardDefinition {
        let url = try #require(Bundle.main.url(forResource: "map", withExtension: "json"))
        return try JSONDecoder().decode(GameCore.BoardDefinition.self, from: Data(contentsOf: url))
    }
}
