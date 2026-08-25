# Map Calibration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct the map orientation, route endpoints and route geometry, place both rural breweries accurately, and display complete Chinese location names.

**Architecture:** Keep game topology in `map.json` and presentation-only coordinates/curves in `BoardPresentationCatalog`. Convert top-left normalized coordinates at the SpriteKit boundary, render routes from validated endpoint and curve metadata, and render the southern brewery association as a separate non-target decoration.

**Tech Stack:** Swift 6, SwiftUI, SpriteKit, CoreGraphics, Swift Testing, Xcode UI Testing.

---

## Workspace note

The App source is currently untracked inside the parent `/Users/didi/Desktop/Interview-learning` repository. A linked worktree would contain the committed specs but not the App source, so this plan is executed in place. Every commit stages only the exact files listed by that task.

Baseline evidence:

- Map-focused serial baseline: 20 tests passed.
- The full parallel test run exposed unrelated pre-existing Nearby/Session timeout failures; representative failures passed when rerun serially.

### Task 1: Correct rule endpoints and vertical coordinate conversion

**Files:**

- Modify: `IndustrialCityBirminghamTests/BoardPresentationCatalogTests.swift`
- Modify: `IndustrialCityBirminghamTests/GameMapSceneTests.swift`
- Modify: `IndustrialCityBirmingham/Features/Map/BoardPresentationCatalog.swift`
- Modify: `IndustrialCityBirmingham/Features/Map/MapNodeFactory.swift`

- [ ] **Step 1: Write failing endpoint and orientation tests**

Add to `BoardPresentationCatalogTests`:

```swift
@Test func southernBreweryAssociationDoesNotReplaceTheRouteEndpoint() throws {
    let routes = try BoardPresentationCatalog.standard.routes(for: bundledBoard())
    let route = try #require(routes.first { $0.id == "kidderminster-worcester" })

    #expect(Set([route.fromLocationID, route.toLocationID]) == ["kidderminster", "worcester"])
}
```

Add to `GameMapSceneTests`:

```swift
@Test func topOriginLocationsConvertToCorrectSpriteKitVerticalOrder() throws {
    let locations = BoardPresentationCatalog.standard.locations
    let stoke = try #require(locations.first { $0.id == "stoke-on-trent" })
    let worcester = try #require(locations.first { $0.id == "worcester" })

    let stokePoint = MapNodeFactory.point(for: stoke, in: GameMapScene.logicalSize)
    let worcesterPoint = MapNodeFactory.point(for: worcester, in: GameMapScene.logicalSize)

    #expect(stokePoint.y > worcesterPoint.y)
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=06658FF6-CF6B-423F-A101-3ADBEFF19C04' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests/BoardPresentationCatalogTests \
  -only-testing:IndustrialCityBirminghamTests/GameMapSceneTests/topOriginLocationsConvertToCorrectSpriteKitVerticalOrder
```

Expected: the southern route reports the farm as an endpoint, and Stoke-on-Trent has a smaller scene y than Worcester.

- [ ] **Step 3: Use `route.endpoints` for presentation routes**

Replace the route mapping body in `BoardPresentationCatalog.routes(for:)` with:

```swift
return try board.routes.map { route in
    guard route.endpoints.count == 2 else {
        throw ValidationError.routeMismatch(route.id)
    }
    return MapRoute(
        id: route.id,
        fromLocationID: route.endpoints[0],
        toLocationID: route.endpoints[1]
    )
}
```

- [ ] **Step 4: Convert top-origin coordinates at the SpriteKit boundary**

Replace `MapNodeFactory.point(for:in:)` with:

```swift
static func point(for location: MapLocation, in size: CGSize) -> CGPoint {
    CGPoint(
        x: location.x * size.width,
        y: (1 - location.y) * size.height
    )
}
```

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the Step 2 command again.

Expected: both new tests and all existing tests in the selected suites pass.

- [ ] **Step 6: Commit Task 1**

```bash
git add \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/BoardPresentationCatalog.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/MapNodeFactory.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/BoardPresentationCatalogTests.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/GameMapSceneTests.swift
git commit -m "fix: correct map orientation and route endpoints"
```

### Task 2: Add validated presentation geometry for all routes

**Files:**

- Modify: `IndustrialCityBirminghamTests/BoardPresentationCatalogTests.swift`
- Modify: `IndustrialCityBirmingham/Features/Map/BoardPresentationCatalog.swift`

- [ ] **Step 1: Write failing catalog completeness and rural brewery tests**

Add:

```swift
@Test func routePresentationCoversEveryRulesRouteExactly() throws {
    let board = try bundledBoard()
    let presentations = BoardPresentationCatalog.standard.routePresentations

    #expect(presentations.count == 39)
    #expect(Set(presentations.map(\.id)) == Set(board.routes.map(\.id)))
    #expect(try BoardPresentationCatalog.standard.validate(board: board))
}

@Test func ruralBreweryPresentationsPreserveDifferentRuleSemantics() throws {
    let board = try bundledBoard()
    let north = try #require(board.routes.first { $0.id == "cannock-cannock-farm" })
    let south = try #require(board.routes.first { $0.id == "kidderminster-worcester" })
    let southPresentation = try #require(
        BoardPresentationCatalog.standard.presentation(forRouteID: south.id)
    )

    #expect(Set(north.endpoints) == ["cannock", "cannock-farm"])
    #expect(Set(south.endpoints) == ["kidderminster", "worcester"])
    #expect(southPresentation.spur?.locationID == "kidderminster-worcester-farm")
    #expect(southPresentation.spur?.t == 0.5)
}
```

- [ ] **Step 2: Run and verify RED**

Run:

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=06658FF6-CF6B-423F-A101-3ADBEFF19C04' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests/BoardPresentationCatalogTests
```

Expected: compile failure because route presentation types and APIs do not exist.

- [ ] **Step 3: Add presentation value types**

Add above `BoardPresentationCatalog`:

```swift
nonisolated struct MapNormalizedPoint: Equatable, Sendable {
    let x: Double
    let y: Double

    var isValid: Bool {
        x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }

    func point(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: (1 - y) * size.height)
    }
}

nonisolated struct MapRouteSpur: Equatable, Sendable {
    let locationID: String
    let t: Double
}

nonisolated struct MapRoutePresentation: Identifiable, Equatable, Sendable {
    let id: String
    let controlPoints: [MapNormalizedPoint]
    let spur: MapRouteSpur?

    init(
        id: String,
        controlPoints: [MapNormalizedPoint] = [],
        spur: MapRouteSpur? = nil
    ) {
        self.id = id
        self.controlPoints = controlPoints
        self.spur = spur
    }
}
```

Add `let routePresentations: [MapRoutePresentation]` to the catalog and:

```swift
func presentation(forRouteID id: String) -> MapRoutePresentation? {
    routePresentations.first { $0.id == id }
}
```

- [ ] **Step 4: Recalibrate the 27 locations**

Replace the standard location list with the following top-origin coordinates:

```swift
locations: [
    .init(id: "stoke-on-trent", name: "特伦特河畔斯托克", x: 0.344, y: 0.129),
    .init(id: "leek", name: "利克", x: 0.489, y: 0.053),
    .init(id: "belper", name: "贝尔珀", x: 0.806, y: 0.065),
    .init(id: "derby", name: "德比", x: 0.828, y: 0.188),
    .init(id: "uttoxeter", name: "尤托克西特", x: 0.528, y: 0.188),
    .init(id: "stone", name: "斯通", x: 0.217, y: 0.218),
    .init(id: "stafford", name: "斯塔福德", x: 0.289, y: 0.318),
    .init(id: "cannock", name: "坎诺克", x: 0.389, y: 0.418),
    .init(id: "cannock-farm", name: "坎诺克乡村酒桶", x: 0.267, y: 0.418),
    .init(id: "burton-on-trent", name: "特伦特河畔伯顿", x: 0.689, y: 0.329),
    .init(id: "tamworth", name: "塔姆沃思", x: 0.706, y: 0.447),
    .init(id: "walsall", name: "沃尔索尔", x: 0.478, y: 0.506),
    .init(id: "wolverhampton", name: "伍尔弗汉普顿", x: 0.283, y: 0.500),
    .init(id: "coalbrookdale", name: "科尔布鲁克代尔", x: 0.122, y: 0.535),
    .init(id: "dudley", name: "达德利", x: 0.328, y: 0.600),
    .init(id: "birmingham", name: "伯明翰", x: 0.589, y: 0.629),
    .init(id: "nuneaton", name: "纳尼顿", x: 0.789, y: 0.541),
    .init(id: "coventry", name: "考文垂", x: 0.833, y: 0.665),
    .init(id: "redditch", name: "雷迪奇", x: 0.544, y: 0.753),
    .init(id: "kidderminster", name: "基德明斯特", x: 0.217, y: 0.706),
    .init(id: "worcester", name: "伍斯特", x: 0.233, y: 0.847),
    .init(id: "kidderminster-worcester-farm", name: "基德明斯特—伍斯特乡村酒桶", x: 0.106, y: 0.776),
    .init(id: "warrington", name: "沃灵顿", x: 0.200, y: 0.018),
    .init(id: "nottingham", name: "诺丁汉", x: 0.928, y: 0.112),
    .init(id: "shrewsbury", name: "什鲁斯伯里", x: 0.028, y: 0.424),
    .init(id: "gloucester", name: "格洛斯特", x: 0.083, y: 0.929),
    .init(id: "oxford", name: "牛津", x: 0.678, y: 0.871),
]
```

- [ ] **Step 5: Add all 39 route presentations**

Use this presentation-only geometry. A point is top-origin normalized and does not alter rule topology:

```swift
routePresentations: [
    .init(id: "stoke-on-trent-warrington", controlPoints: [.init(x: 0.270, y: 0.045)]),
    .init(id: "leek-stoke-on-trent", controlPoints: [.init(x: 0.420, y: 0.080)]),
    .init(id: "belper-leek", controlPoints: [.init(x: 0.650, y: 0.020)]),
    .init(id: "belper-derby", controlPoints: [.init(x: 0.840, y: 0.120)]),
    .init(id: "derby-nottingham", controlPoints: [.init(x: 0.885, y: 0.145)]),
    .init(id: "derby-uttoxeter"),
    .init(id: "stone-uttoxeter", controlPoints: [.init(x: 0.370, y: 0.195)]),
    .init(id: "stoke-on-trent-stone", controlPoints: [.init(x: 0.260, y: 0.160)]),
    .init(id: "burton-on-trent-stone", controlPoints: [.init(x: 0.450, y: 0.220)]),
    .init(id: "burton-on-trent-derby", controlPoints: [.init(x: 0.760, y: 0.250)]),
    .init(id: "stafford-stone", controlPoints: [.init(x: 0.240, y: 0.270)]),
    .init(id: "cannock-stafford", controlPoints: [.init(x: 0.340, y: 0.360)]),
    .init(id: "cannock-cannock-farm"),
    .init(id: "burton-on-trent-cannock", controlPoints: [.init(x: 0.550, y: 0.370)]),
    .init(id: "cannock-wolverhampton", controlPoints: [.init(x: 0.340, y: 0.465)]),
    .init(id: "cannock-walsall", controlPoints: [.init(x: 0.430, y: 0.460)]),
    .init(id: "burton-on-trent-walsall", controlPoints: [.init(x: 0.580, y: 0.440)]),
    .init(id: "burton-on-trent-tamworth", controlPoints: [.init(x: 0.700, y: 0.390)]),
    .init(id: "coalbrookdale-wolverhampton"),
    .init(id: "coalbrookdale-shrewsbury", controlPoints: [.init(x: 0.070, y: 0.485)]),
    .init(id: "walsall-wolverhampton"),
    .init(id: "tamworth-walsall", controlPoints: [.init(x: 0.600, y: 0.485)]),
    .init(id: "nuneaton-tamworth"),
    .init(id: "birmingham-tamworth", controlPoints: [.init(x: 0.650, y: 0.540)]),
    .init(id: "birmingham-walsall"),
    .init(id: "dudley-wolverhampton"),
    .init(id: "coalbrookdale-kidderminster", controlPoints: [.init(x: 0.120, y: 0.640)]),
    .init(id: "dudley-kidderminster"),
    .init(id: "birmingham-dudley", controlPoints: [.init(x: 0.450, y: 0.610)]),
    .init(id: "birmingham-nuneaton", controlPoints: [.init(x: 0.700, y: 0.600)]),
    .init(id: "coventry-nuneaton"),
    .init(id: "birmingham-coventry"),
    .init(id: "birmingham-worcester", controlPoints: [.init(x: 0.500, y: 0.720), .init(x: 0.350, y: 0.820)]),
    .init(
        id: "kidderminster-worcester",
        controlPoints: [.init(x: 0.250, y: 0.780)],
        spur: .init(locationID: "kidderminster-worcester-farm", t: 0.5)
    ),
    .init(id: "gloucester-worcester"),
    .init(id: "gloucester-redditch", controlPoints: [.init(x: 0.300, y: 0.850)]),
    .init(id: "birmingham-redditch"),
    .init(id: "oxford-redditch"),
    .init(id: "birmingham-oxford", controlPoints: [.init(x: 0.660, y: 0.740)]),
]
```

- [ ] **Step 6: Extend catalog validation**

Add validation errors and checks:

```swift
case routePresentationMismatch
case invalidRoutePresentation(String)
case invalidRouteSpur(String)
```

```swift
let ruleRoutesByID = Dictionary(uniqueKeysWithValues: board.routes.map { ($0.id, $0) })
let presentationIDs = routePresentations.map(\.id)
guard Set(presentationIDs).count == presentationIDs.count,
      Set(presentationIDs) == Set(ruleRoutesByID.keys)
else { throw ValidationError.routePresentationMismatch }

for presentation in routePresentations {
    guard presentation.controlPoints.count <= 2,
          presentation.controlPoints.allSatisfy(\.isValid)
    else { throw ValidationError.invalidRoutePresentation(presentation.id) }

    guard let spur = presentation.spur else { continue }
    guard spur.t.isFinite, (0...1).contains(spur.t),
          let route = ruleRoutesByID[presentation.id]
    else { throw ValidationError.invalidRouteSpur(presentation.id) }
    let extraAdjacent = Set(route.adjacentLocationIDs).subtracting(route.endpoints)
    guard extraAdjacent == [spur.locationID] else {
        throw ValidationError.invalidRouteSpur(presentation.id)
    }
}
```

- [ ] **Step 7: Run and verify GREEN**

Run the Step 2 command again.

Expected: all `BoardPresentationCatalogTests` pass.

- [ ] **Step 8: Commit Task 2**

```bash
git add \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/BoardPresentationCatalog.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/BoardPresentationCatalogTests.swift
git commit -m "feat: add calibrated map presentation geometry"
```

### Task 3: Render curved paths and the southern brewery spur

**Files:**

- Modify: `IndustrialCityBirminghamTests/GameMapSceneTests.swift`
- Modify: `IndustrialCityBirmingham/Features/Map/MapNodeFactory.swift`
- Modify: `IndustrialCityBirmingham/Features/Map/GameMapScene.swift`

- [ ] **Step 1: Write failing curve, midpoint, and decoration tests**

Add:

```swift
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
    let scene = GameMapScene()
    scene.configure(state: DemoFixture.match(playerCount: 4), highlightedIDs: [])

    #expect(scene.childNode(withName: "//decoration:spur:kidderminster-worcester") != nil)
    #expect(GameMapScene.targetID(fromNodeName: "decoration:spur:kidderminster-worcester") == nil)
}
```

Update `targetLookupFindsLocationAndRouteAtScenePoints` so `routePoint` comes from:

```swift
let presentation = BoardPresentationCatalog.standard.presentation(forRouteID: route.id)
    ?? .init(id: route.id)
let routePoint = MapNodeFactory.routePoint(
    t: 0.5,
    from: routeStart,
    to: routeEnd,
    in: GameMapScene.logicalSize,
    presentation: presentation
)
```

- [ ] **Step 2: Run and verify RED**

Run:

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=06658FF6-CF6B-423F-A101-3ADBEFF19C04' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests/GameMapSceneTests
```

Expected: compile failure because `routePath`, `routePoint`, and spur rendering do not exist.

- [ ] **Step 3: Add reusable route geometry functions**

Add to `MapNodeFactory`:

```swift
static func routePath(
    from start: MapLocation,
    to end: MapLocation,
    in size: CGSize,
    presentation: MapRoutePresentation
) -> CGPath {
    let startPoint = point(for: start, in: size)
    let endPoint = point(for: end, in: size)
    let controls = presentation.controlPoints.map { $0.point(in: size) }
    let path = CGMutablePath()
    path.move(to: startPoint)
    switch controls.count {
    case 1:
        path.addQuadCurve(to: endPoint, control: controls[0])
    case 2:
        path.addCurve(to: endPoint, control1: controls[0], control2: controls[1])
    default:
        path.addLine(to: endPoint)
    }
    return path
}

static func routePoint(
    t rawT: Double,
    from start: MapLocation,
    to end: MapLocation,
    in size: CGSize,
    presentation: MapRoutePresentation
) -> CGPoint {
    let t = CGFloat(min(max(rawT, 0), 1))
    let inverse = 1 - t
    let startPoint = point(for: start, in: size)
    let endPoint = point(for: end, in: size)
    let controls = presentation.controlPoints.map { $0.point(in: size) }
    switch controls.count {
    case 1:
        return CGPoint(
            x: inverse * inverse * startPoint.x + 2 * inverse * t * controls[0].x + t * t * endPoint.x,
            y: inverse * inverse * startPoint.y + 2 * inverse * t * controls[0].y + t * t * endPoint.y
        )
    case 2:
        return CGPoint(
            x: inverse * inverse * inverse * startPoint.x
                + 3 * inverse * inverse * t * controls[0].x
                + 3 * inverse * t * t * controls[1].x
                + t * t * t * endPoint.x,
            y: inverse * inverse * inverse * startPoint.y
                + 3 * inverse * inverse * t * controls[0].y
                + 3 * inverse * t * t * controls[1].y
                + t * t * t * endPoint.y
        )
    default:
        return CGPoint(
            x: inverse * startPoint.x + t * endPoint.x,
            y: inverse * startPoint.y + t * endPoint.y
        )
    }
}
```

- [ ] **Step 4: Make route nodes use the calibrated path and midpoint**

Add `presentation: MapRoutePresentation` to `routeNode`, replace its path construction with `routePath`, and place a highlighted label at:

```swift
let midpoint = routePoint(
    t: 0.5, from: start, to: end, in: size, presentation: presentation
)
```

The visible `SKShapeNode` and its 44 pt hit child both receive the same `CGPath`.

- [ ] **Step 5: Add a separate non-target brewery spur node**

Add:

```swift
static func brewerySpurNode(
    routeID: String,
    from farm: MapLocation,
    to routePoint: CGPoint,
    in size: CGSize
) -> SKShapeNode {
    let path = CGMutablePath()
    path.move(to: point(for: farm, in: size))
    path.addQuadCurve(
        to: routePoint,
        control: CGPoint(
            x: (point(for: farm, in: size).x + routePoint.x) / 2,
            y: routePoint.y
        )
    )
    let node = SKShapeNode(path: path)
    node.name = "decoration:spur:\(routeID)"
    node.zPosition = 9
    node.strokeColor = brass.withAlphaComponent(0.8)
    node.lineWidth = 2.5
    node.lineCap = .round
    return node
}
```

Teach `applyInteractionMetrics` to keep `decoration:spur:` at `2.5 * metrics.sceneUnitsPerPoint` without adding a hit area.

- [ ] **Step 6: Compose route geometry in `GameMapScene.configure`**

For each state route:

```swift
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
contentLayer.addChild(MapNodeFactory.routeNode(
    for: route,
    from: start,
    to: end,
    in: Self.logicalSize,
    presentation: presentation,
    isHighlighted: highlightedIDs.contains(route.id)
))
```

- [ ] **Step 7: Run and verify GREEN**

Run the Step 2 command again.

Expected: every `GameMapSceneTests` test passes.

- [ ] **Step 8: Commit Task 3**

```bash
git add \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/MapNodeFactory.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/GameMapScene.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/GameMapSceneTests.swift
git commit -m "feat: render calibrated map curves and brewery spur"
```

### Task 4: Render complete Chinese labels without ellipses

**Files:**

- Modify: `IndustrialCityBirminghamTests/GameMapSceneTests.swift`
- Modify: `IndustrialCityBirmingham/Features/Map/MapNodeFactory.swift`

- [ ] **Step 1: Write a failing complete-label test**

Add:

```swift
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
```

- [ ] **Step 2: Run and verify RED**

Run the GameMapSceneTests command from Task 3.

Expected: the current badge contains one truncated label.

- [ ] **Step 3: Replace `shortName` with a two-line layout**

Add:

```swift
private static func labelLines(for text: String) -> [String] {
    guard text.count > 7 else { return [text] }
    if let separator = text.firstIndex(of: "—") {
        return [String(text[..<separator]), String(text[text.index(after: separator)...])]
    }
    let split = text.index(text.startIndex, offsetBy: (text.count + 1) / 2)
    return [String(text[..<split]), String(text[split...])]
}
```

Replace `nameBadge` with:

```swift
private static func nameBadge(
    text: String,
    name: String,
    position: CGPoint,
    highlighted: Bool
) -> SKShapeNode {
    let lines = labelLines(for: text)
    let longestLineCount = lines.map(\.count).max() ?? 1
    let fontSize: CGFloat = longestLineCount <= 4 ? 10 : (longestLineCount <= 7 ? 9 : 8)
    let width = max(34, CGFloat(longestLineCount) * fontSize + 14)
    let height: CGFloat = lines.count == 1 ? 20 : 34
    let badge = SKShapeNode(
        rectOf: CGSize(width: width, height: height),
        cornerRadius: 6
    )
    badge.name = name
    badge.position = position
    badge.zPosition = 5
    badge.fillColor = highlighted ? brass.withAlphaComponent(0.96) : ink.withAlphaComponent(0.88)
    badge.strokeColor = highlighted ? porcelain : brass.withAlphaComponent(0.8)
    badge.lineWidth = 1
    badge.isUserInteractionEnabled = false

    let lineHeight = fontSize + 2
    for (index, line) in lines.enumerated() {
        let label = SKLabelNode(text: line)
        label.name = "text-line-\(index)"
        label.fontName = "PingFangSC-Semibold"
        label.fontSize = fontSize
        label.fontColor = highlighted ? ink : porcelain
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.position.y = (CGFloat(lines.count - 1) / 2 - CGFloat(index)) * lineHeight
        label.isUserInteractionEnabled = false
        badge.addChild(label)
    }
    return badge
}
```

Pass `location.name` directly, move two-line location badges to y 34 instead of y 26, pass `"\(start.name)—\(end.name)"` directly for route labels, and remove `shortName`.

- [ ] **Step 4: Run and verify GREEN**

Run the Task 3 command.

Expected: every GameMapScene test passes and the long-name test joins to the full Chinese location name.

- [ ] **Step 5: Commit Task 4**

```bash
git add \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/MapNodeFactory.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/GameMapSceneTests.swift
git commit -m "feat: show complete Chinese map labels"
```

### Task 5: Regression verification and visual evidence

**Files:**

- Verify: `IndustrialCityBirmingham/Features/Map/*.swift`
- Verify: `IndustrialCityBirminghamTests/BoardPresentationCatalogTests.swift`
- Verify: `IndustrialCityBirminghamTests/GameMapSceneTests.swift`
- Verify: `IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift`

- [ ] **Step 1: Run the complete unit suite serially**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=06658FF6-CF6B-423F-A101-3ADBEFF19C04' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests
```

Expected: all unit tests pass. Simulator diagnostic warnings are acceptable; test failures are not.

- [ ] **Step 2: Run the landscape visual evidence UI test**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=06658FF6-CF6B-423F-A101-3ADBEFF19C04' \
  -resultBundlePath /tmp/map-calibration.xcresult \
  -only-testing:IndustrialCityBirminghamUITests/FriendsPlayableUITests/testRealFixtureLandscapeVisualEvidence
```

Expected: UI test passes and the result bundle contains a landscape map attachment.

- [ ] **Step 3: Export and inspect the screenshot**

```bash
attachment_dir=$(mktemp -d /tmp/map-calibration-attachments.XXXXXX)
xcrun xcresulttool export attachments \
  --path /tmp/map-calibration.xcresult \
  --output-path "$attachment_dir"
```

Inspect the exported PNG and verify:

- north/south orientation matches the approved reference;
- the two rural breweries are west of Cannock and west of the Kidderminster–Worcester corridor;
- the southern brewery is not the route endpoint;
- long Chinese labels contain no ellipses;
- major central routes remain distinguishable.

- [ ] **Step 4: Confirm no official art entered App resources**

```bash
find IndustrialCityBirmingham/Assets.xcassets -type f -print0 \
  | sort -z \
  | xargs -0 shasum -a 256
```

Expected: exactly these five existing files and hashes; no newly added official photo, PDF, map, icon, or font:

```text
9af65086fa30b49252fae1a1225731691de794f7775af74d71befeb507d12b7c  IndustrialCityBirmingham/Assets.xcassets/AccentColor.colorset/Contents.json
d776cfae1b33325f70befa1b0fc5e5420c660655603409e8588d94fd8fc6e112  IndustrialCityBirmingham/Assets.xcassets/AppIcon.appiconset/Contents.json
0fd49ba3c3585c709678e0046a821c3c60685ec7063720d30d3a3448be3a208b  IndustrialCityBirmingham/Assets.xcassets/Contents.json
0c786ee122528f35b4bbe5c5b18a28fc6aeec0fd098d96375f48dbf33e239076  IndustrialCityBirmingham/Assets.xcassets/IndustrialMap.imageset/Contents.json
fc384bdecffb59a5a72c20d3aee7c933b5ae575472b0d82b36ee8622ff9b07a6  IndustrialCityBirmingham/Assets.xcassets/IndustrialMap.imageset/industrial-map.png
```

- [ ] **Step 5: Record final scoped status**

```bash
git status --short -- \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/BoardPresentationCatalogTests.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/GameMapSceneTests.swift \
  Brass-Birmingham/ui-prototype/docs/superpowers
```

Expected: no unstaged changes in the implemented source/test files; `.superpowers/` remains ignored.
