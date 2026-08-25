# Route Era Visualization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show canal-only, rail-only, and dual-era routes directly on the map while dimming only unbuilt routes that cannot be built in the current era.

**Architecture:** Project route eras from the verified board definition into `MapRoute`, resolve a pure visual style from route state plus current era, and render each route as a named SpriteKit container with separate era, owner, highlight, and hit-test layers. Keep the legend in SwiftUI so it stays fixed while the SpriteKit map pans and zooms, and derive VoiceOver text from the same era classification.

**Tech Stack:** Swift 6, SwiftUI, SpriteKit, CoreGraphics, Swift Testing, Xcode UI Testing.

---

## Workspace note

The Git repository root is `/Users/didi/Desktop/Interview-learning`; the App root is `Brass-Birmingham/ui-prototype`. Much of the original App source is still untracked in the parent repository, so do not use a linked worktree and do not stage unrelated paths. Every commit below stages only the exact task files.

Use the currently available `IndustrialCity-iPad` simulator with destination `platform=iOS Simulator,id=06658FF6-CF6B-423F-A101-3ADBEFF19C04`.

Run all commands from `/Users/didi/Desktop/Interview-learning/Brass-Birmingham/ui-prototype` unless a command explicitly changes directory.

### Task 1: Carry allowed eras into every presentation route

**Files:**

- Modify: `IndustrialCityBirmingham/Models/DemoModels.swift:98-110`
- Modify: `IndustrialCityBirmingham/Features/Map/BoardPresentationCatalog.swift:80-100`
- Modify: `IndustrialCityBirminghamTests/BoardPresentationCatalogTests.swift`
- Modify: `IndustrialCityBirminghamTests/DemoFixtureTests.swift`

- [ ] **Step 1: Write failing projection and Codable tests**

Add to `BoardPresentationCatalogTests`:

```swift
@Test func rulesRouteErasProjectIntoPresentationRoutesExactly() throws {
    let routes = try BoardPresentationCatalog.standard.routes(for: bundledBoard())

    #expect(routes.filter { $0.availableEras == [.canal] }.map(\.id) == ["burton-on-trent-walsall"])
    #expect(routes.filter { $0.availableEras == [.rail] }.count == 8)
    #expect(routes.filter { $0.availableEras == [.canal, .rail] }.count == 30)
    #expect(routes.first { $0.id == "belper-leek" }?.availableEras == [.rail])
    #expect(routes.first { $0.id == "birmingham-coventry" }?.availableEras == [.canal, .rail])
}
```

Add to `DemoFixtureTests`:

```swift
@Test func mapRouteCodablePreservesAllowedErasAndDefaultsLegacyDataToBoth() throws {
    let route = MapRoute(
        id: "rail-only", fromLocationID: "a", toLocationID: "b",
        availableEras: [.rail]
    )
    let encoded = try JSONEncoder().encode(route)
    #expect(try JSONDecoder().decode(MapRoute.self, from: encoded) == route)

    let legacy = Data(#"{"id":"legacy","fromLocationID":"a","toLocationID":"b"}"#.utf8)
    let decoded = try JSONDecoder().decode(MapRoute.self, from: legacy)
    #expect(decoded.availableEras == [.canal, .rail])
    #expect(decoded.placedLink == nil)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=06658FF6-CF6B-423F-A101-3ADBEFF19C04' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests/BoardPresentationCatalogTests \
  -only-testing:IndustrialCityBirminghamTests/DemoFixtureTests/mapRouteCodablePreservesAllowedErasAndDefaultsLegacyDataToBoth
```

Expected: compile failure because `MapRoute` has no `availableEras` member or initializer parameter.

- [ ] **Step 3: Add compatible era storage to `MapRoute`**

Replace `MapPlacedLink.Era` and `MapRoute` with:

```swift
nonisolated struct MapPlacedLink: Equatable, Codable, Sendable {
    enum Era: String, CaseIterable, Codable, Equatable, Sendable { case canal, rail }
    let ownerID: String
    let ownerColor: PlayerColor
    let era: Era
}

nonisolated struct MapRoute: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let fromLocationID: String
    let toLocationID: String
    let availableEras: [MapPlacedLink.Era]
    var placedLink: MapPlacedLink?

    init(
        id: String,
        fromLocationID: String,
        toLocationID: String,
        availableEras: [MapPlacedLink.Era] = [.canal, .rail],
        placedLink: MapPlacedLink? = nil
    ) {
        self.id = id
        self.fromLocationID = fromLocationID
        self.toLocationID = toLocationID
        self.availableEras = availableEras
        self.placedLink = placedLink
    }

    private enum CodingKeys: String, CodingKey {
        case id, fromLocationID, toLocationID, availableEras, placedLink
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        fromLocationID = try values.decode(String.self, forKey: .fromLocationID)
        toLocationID = try values.decode(String.self, forKey: .toLocationID)
        availableEras = try values.decodeIfPresent(
            [MapPlacedLink.Era].self, forKey: .availableEras
        ) ?? [.canal, .rail]
        placedLink = try values.decodeIfPresent(MapPlacedLink.self, forKey: .placedLink)
    }
}
```

- [ ] **Step 4: Project verified board eras in stable order**

Replace `BoardPresentationCatalog.routes(for:)` and extend `ValidationError`:

```swift
func routes(for board: GameCore.BoardDefinition) throws -> [MapRoute] {
    _ = try validate(board: board)
    return try board.routes.map { route in
        guard route.endpoints.count == 2 else {
            throw ValidationError.routeMismatch(route.id)
        }
        let allowed = route.eras.map { era -> MapPlacedLink.Era in
            switch era {
            case .canal: .canal
            case .rail: .rail
            }
        }
        let availableEras = MapPlacedLink.Era.allCases.filter(allowed.contains)
        guard availableEras.isEmpty == false else {
            throw ValidationError.missingRouteEra(route.id)
        }
        return MapRoute(
            id: route.id,
            fromLocationID: route.endpoints[0],
            toLocationID: route.endpoints[1],
            availableEras: availableEras
        )
    }
}

enum ValidationError: Error, Equatable {
    case locationMismatch
    case routeMismatch(String)
    case routePresentationMismatch
    case invalidRoutePresentation(String)
    case invalidRouteSpur(String)
    case missingRouteEra(String)
}
```

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the Step 2 command again.

Expected: all selected tests pass; the counts are exactly 1 canal-only, 8 rail-only, and 30 dual-era.

- [ ] **Step 6: Commit Task 1**

```bash
git -C /Users/didi/Desktop/Interview-learning add \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Models/DemoModels.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/BoardPresentationCatalog.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/BoardPresentationCatalogTests.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/DemoFixtureTests.swift
git -C /Users/didi/Desktop/Interview-learning commit -m "feat: project route era availability"
```

### Task 2: Resolve route type and current-era availability with pure logic

**Files:**

- Create: `IndustrialCityBirmingham/Features/Map/MapRouteEraStyle.swift`
- Modify: `IndustrialCityBirminghamTests/GameMapSceneTests.swift`

- [ ] **Step 1: Write failing style-resolution tests**

Add to `GameMapSceneTests`:

```swift
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

private func route(
    eras: [MapPlacedLink.Era], placed: Bool = false
) -> MapRoute {
    MapRoute(
        id: "test-route", fromLocationID: "a", toLocationID: "b",
        availableEras: eras,
        placedLink: placed
            ? .init(ownerID: "owner", ownerColor: .amber, era: eras[0])
            : nil
    )
}
```

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=06658FF6-CF6B-423F-A101-3ADBEFF19C04' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests/GameMapSceneTests/routeEraStyleClassifiesAllThreeAllowedEraShapes \
  -only-testing:IndustrialCityBirminghamTests/GameMapSceneTests/unavailableUnbuiltRouteDimsButBuiltAndUnknownEraRoutesDoNot \
  -only-testing:IndustrialCityBirminghamTests/GameMapSceneTests/visibleMatchEraMapsToPresentationEra
```

Expected: compile failure because `MapRouteEraStyle` and `MapRouteEraKind` do not exist.

- [ ] **Step 3: Create the pure style resolver and shared palette**

Create `MapRouteEraStyle.swift`:

```swift
import UIKit

nonisolated enum MapRouteEraKind: String, CaseIterable, Equatable, Sendable {
    case canalOnly
    case railOnly
    case both

    var chineseLabel: String {
        switch self {
        case .canalOnly: "运河专用"
        case .railOnly: "铁路专用"
        case .both: "两时代通用"
        }
    }
}

nonisolated struct MapRouteEraStyle: Equatable, Sendable {
    let kind: MapRouteEraKind
    let opacity: Double
    let isAvailableNow: Bool

    static func resolve(
        route: MapRoute,
        currentEra: MapPlacedLink.Era?
    ) -> MapRouteEraStyle {
        let hasCanal = route.availableEras.contains(.canal)
        let hasRail = route.availableEras.contains(.rail)
        let kind: MapRouteEraKind
        switch (hasCanal, hasRail) {
        case (true, false): kind = .canalOnly
        case (false, true): kind = .railOnly
        default: kind = .both
        }

        let available = currentEra.map(route.availableEras.contains) ?? true
        let opacity = route.placedLink == nil && available == false ? 0.25 : 1
        return .init(kind: kind, opacity: opacity, isAvailableNow: available)
    }

    static func currentEra(from visibleName: String) -> MapPlacedLink.Era? {
        switch visibleName {
        case "运河时代": .canal
        case "铁路时代": .rail
        default: nil
        }
    }
}

@MainActor
enum MapRouteEraPalette {
    static let canal = UIColor(red: 0.24, green: 0.73, blue: 0.76, alpha: 1)
    static let rail = UIColor(red: 0.64, green: 0.69, blue: 0.72, alpha: 1)
}
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command again.

Expected: all three selected tests pass.

- [ ] **Step 5: Commit Task 2**

```bash
git -C /Users/didi/Desktop/Interview-learning add \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/MapRouteEraStyle.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/GameMapSceneTests.swift
git -C /Users/didi/Desktop/Interview-learning commit -m "feat: resolve map route era styles"
```

### Task 3: Render named SpriteKit layers without breaking route interaction

**Files:**

- Modify: `IndustrialCityBirmingham/Features/Map/GameMapScene.swift:117-165`
- Modify: `IndustrialCityBirmingham/Features/Map/MapNodeFactory.swift:138-241`
- Modify: `IndustrialCityBirminghamTests/GameMapSceneTests.swift`

- [ ] **Step 1: Replace root-shape assertions and add failing layer tests**

Add `import Foundation` at the top of `GameMapSceneTests.swift`. Update existing route tests so the `route:<id>` root is treated as `SKNode`; inspect named children instead of casting the root to `SKShapeNode`. Add:

```swift
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

private func bundledBoard() throws -> GameCore.BoardDefinition {
    let url = try #require(Bundle.main.url(forResource: "map", withExtension: "json"))
    return try JSONDecoder().decode(GameCore.BoardDefinition.self, from: Data(contentsOf: url))
}
```

Change existing assertions as follows:

```swift
let route = try #require(scene.childNode(withName: "//route:\(routeID)"))
let routeHit = try #require(route.childNode(withName: "route-hit-area") as? SKShapeNode)
let highlight = try #require(route.childNode(withName: "route-highlight") as? SKShapeNode)
#expect(highlight.glowWidth > 0)
```

- [ ] **Step 2: Run the map scene suite and verify RED**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=06658FF6-CF6B-423F-A101-3ADBEFF19C04' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests/GameMapSceneTests
```

Expected: new tests fail because route roots still contain only one shape and `configure` does not pass the current era.

- [ ] **Step 3: Pass the current era into the route factory**

In `GameMapScene.configure`, compute once before the route loop:

```swift
let currentEra = MapRouteEraStyle.currentEra(from: state.era)
```

Then extend the `routeNode` call:

```swift
MapNodeFactory.routeNode(
    for: route,
    from: start,
    to: end,
    in: Self.logicalSize,
    presentation: presentation,
    currentEra: currentEra,
    isHighlighted: highlightedIDs.contains(route.id)
)
```

- [ ] **Step 4: Replace the monolithic route node with named layers**

Replace `routeNode` and add the two helpers below it:

```swift
static func routeNode(
    for route: MapRoute,
    from start: MapLocation,
    to end: MapLocation,
    in size: CGSize,
    presentation: MapRoutePresentation,
    currentEra: MapPlacedLink.Era?,
    isHighlighted: Bool
) -> SKNode {
    let path = routePath(from: start, to: end, in: size, presentation: presentation)
    let style = MapRouteEraStyle.resolve(route: route, currentEra: currentEra)
    let container = SKNode()
    container.name = "route:\(route.id)"
    container.zPosition = 10
    container.alpha = CGFloat(style.opacity)
    container.userData = [
        "isHighlighted": isHighlighted,
        "eraKind": style.kind.rawValue,
        "sourcePath": UIBezierPath(cgPath: path),
    ]

    if isHighlighted {
        let highlight = strokeNode(
            name: "route-highlight", path: path, color: brass,
            width: 11, zPosition: -3
        )
        highlight.glowWidth = 5
        container.addChild(highlight)
    }

    if style.kind != .railOnly {
        container.addChild(strokeNode(
            name: "route-era-canal", path: path,
            color: MapRouteEraPalette.canal,
            width: style.kind == .both ? 8 : 6,
            zPosition: -2
        ))
    }
    if style.kind != .canalOnly {
        let railPath = style.kind == .railOnly
            ? dashedPath(path, dash: 9, gap: 6)
            : path
        container.addChild(strokeNode(
            name: "route-era-rail", path: railPath,
            color: MapRouteEraPalette.rail,
            width: style.kind == .both ? 3 : 5,
            zPosition: -1
        ))
    }

    if let link = route.placedLink {
        container.addChild(strokeNode(
            name: "route-owner", path: path,
            color: ownerColor(link.ownerColor), width: 4, zPosition: 1
        ))
        container.userData?["ownerID"] = link.ownerID
        container.userData?["era"] = link.era.rawValue
    }

    let hitArea = strokeNode(
        name: routeHitAreaName, path: path,
        color: UIColor.white.withAlphaComponent(0.001),
        width: 44, zPosition: 2
    )
    hitArea.isUserInteractionEnabled = false
    container.addChild(hitArea)

    if isHighlighted {
        let midpoint = routePoint(
            t: 0.5, from: start, to: end, in: size, presentation: presentation
        )
        container.addChild(nameBadge(
            text: "\(start.name)—\(end.name)", name: "route-label",
            position: CGPoint(x: midpoint.x, y: midpoint.y + 18), highlighted: true
        ))
    }
    return container
}

private static func strokeNode(
    name: String,
    path: CGPath,
    color: UIColor,
    width: CGFloat,
    zPosition: CGFloat
) -> SKShapeNode {
    let node = SKShapeNode(path: path)
    node.name = name
    node.strokeColor = color
    node.lineWidth = width
    node.lineCap = .round
    node.zPosition = zPosition
    node.isUserInteractionEnabled = false
    return node
}

private static func dashedPath(
    _ path: CGPath,
    dash: CGFloat,
    gap: CGFloat
) -> CGPath {
    path.copy(dashingWithPhase: 0, lengths: [dash, gap])
}
```

- [ ] **Step 5: Make zoom metrics update every named layer and rail dash rhythm**

Replace the route portion of `applyInteractionMetrics` with:

```swift
guard node.name?.hasPrefix("route:") == true else { continue }
let unit = metrics.sceneUnitsPerPoint
let kind = (node.userData?["eraKind"] as? String).flatMap(MapRouteEraKind.init(rawValue:)) ?? .both

if let highlight = node.childNode(withName: "route-highlight") as? SKShapeNode {
    highlight.lineWidth = 11 * unit
    highlight.glowWidth = 5 * unit
}
if let canal = node.childNode(withName: "route-era-canal") as? SKShapeNode {
    canal.lineWidth = (kind == .both ? 8 : 6) * unit
}
if let rail = node.childNode(withName: "route-era-rail") as? SKShapeNode {
    rail.lineWidth = (kind == .both ? 3 : 5) * unit
    if kind == .railOnly,
       let source = node.userData?["sourcePath"] as? UIBezierPath {
        rail.path = dashedPath(source.cgPath, dash: 9 * unit, gap: 6 * unit)
    }
}
if let owner = node.childNode(withName: "route-owner") as? SKShapeNode {
    owner.lineWidth = 4 * unit
}
if let hitArea = node.childNode(withName: routeHitAreaName) as? SKShapeNode {
    hitArea.lineWidth = 45 * unit
}
node.childNode(withName: "route-label")?.setScale(unit)
```

- [ ] **Step 6: Run map scene tests and verify GREEN**

Run the Step 2 command again.

Expected: all `GameMapSceneTests` pass, including curve hit testing, 44 pt geometry, era layers, owner layer, and highlight layer.

- [ ] **Step 7: Commit Task 3**

```bash
git -C /Users/didi/Desktop/Interview-learning add \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/GameMapScene.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/MapNodeFactory.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/GameMapSceneTests.swift
git -C /Users/didi/Desktop/Interview-learning commit -m "feat: render route era layers"
```

### Task 4: Add the fixed legend and era-aware VoiceOver labels

**Files:**

- Create: `IndustrialCityBirmingham/Features/Map/MapRouteLegend.swift`
- Modify: `IndustrialCityBirmingham/Features/Map/MapRouteEraStyle.swift`
- Modify: `IndustrialCityBirmingham/Features/Map/GameMapView.swift:36-74,161-174`
- Modify: `IndustrialCityBirminghamTests/GameMapSceneTests.swift`

- [ ] **Step 1: Write failing accessibility-label tests**

Add to `GameMapSceneTests`:

```swift
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
```

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=06658FF6-CF6B-423F-A101-3ADBEFF19C04' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests/GameMapSceneTests/routeAccessibilityExplainsTypeAvailabilityAndPlacedOwner
```

Expected: compile failure because `MapRouteAccessibility` does not exist.

- [ ] **Step 3: Add shared accessibility wording**

Append to `MapRouteEraStyle.swift`:

```swift
nonisolated enum MapRouteAccessibility {
    static func label(
        route: MapRoute,
        startName: String,
        endName: String,
        currentEra: MapPlacedLink.Era?,
        ownerName: String?
    ) -> String {
        let style = MapRouteEraStyle.resolve(route: route, currentEra: currentEra)
        var parts = ["\(startName)至\(endName)", style.kind.chineseLabel]
        if let link = route.placedLink {
            let owner = ownerName ?? link.ownerID
            let era = link.era == .canal ? "运河" : "铁路"
            parts.append("\(owner) 已建\(era)")
        } else if style.isAvailableNow == false {
            parts.append("当前时代不可修")
        }
        return parts.joined(separator: "，")
    }
}
```

- [ ] **Step 4: Create a compact non-interactive legend**

Create `MapRouteLegend.swift`:

```swift
import SwiftUI

@MainActor
struct MapRouteLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            row(.canalOnly)
            row(.railOnly)
            row(.both)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(uiColor: UIColor(red: 0.93, green: 0.67, blue: 0.25, alpha: 0.75)))
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("路线图例：运河专用，铁路专用，两时代通用")
    }

    private func row(_ kind: MapRouteEraKind) -> some View {
        HStack(spacing: 7) {
            MapRouteLegendLine(kind: kind)
                .frame(width: 30, height: 9)
            Text(kind.chineseLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
        }
    }
}

@MainActor
private struct MapRouteLegendLine: View {
    let kind: MapRouteEraKind

    var body: some View {
        ZStack {
            if kind != .railOnly {
                Capsule()
                    .fill(Color(uiColor: MapRouteEraPalette.canal))
                    .frame(height: kind == .both ? 8 : 5)
            }
            if kind == .both {
                Capsule()
                    .fill(Color(uiColor: MapRouteEraPalette.rail))
                    .frame(height: 3)
            } else if kind == .railOnly {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 4.5))
                    path.addLine(to: CGPoint(x: 30, y: 4.5))
                }
                .stroke(
                    Color(uiColor: MapRouteEraPalette.rail),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [7, 4])
                )
            }
        }
    }
}
```

- [ ] **Step 5: Overlay the legend and use full Chinese route labels**

Wrap the existing `SpriteView` modifier chain in `GameMapView.body` with:

```swift
ZStack(alignment: .topTrailing) {
    SpriteView(scene: scene)
        .contentShape(Rectangle())
        .simultaneousGesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(tapGesture)
        .onAppear { synchronizeScene(viewportSize: proxy.size) }
        .onChange(of: proxy.size) { _, newSize in
            let appliedTranslation = scene.updateViewport(size: newSize)
            if !isDragging { committedTranslation = appliedTranslation }
            updateCamera()
        }
        .onChange(of: state) { _, _ in synchronizeScene(viewportSize: proxy.size) }
        .onChange(of: highlightedIDs) { _, _ in synchronizeScene(viewportSize: proxy.size) }

    MapRouteLegend()
        .padding(8)
}
```

Keep the existing `.accessibilityRepresentation` on the resulting `ZStack`. Inside its `VStack`, add the legend text before the target buttons so the visual legend has an equivalent VoiceOver element:

```swift
Text("路线图例：运河专用，铁路专用，两时代通用")
    .accessibilityIdentifier("map.routeLegend")
```

Then replace `accessibleTargets` with:

```swift
private var accessibleTargets: [(id: String, label: String)] {
    let locations = state.locations
        .filter { highlightedIDs.contains($0.id) }
        .map { (id: $0.id, label: $0.name) }
    let namesByID = Dictionary(uniqueKeysWithValues: state.locations.map { ($0.id, $0.name) })
    let playersByID = Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, $0.name) })
    let currentEra = MapRouteEraStyle.currentEra(from: state.era)
    let routes = state.routes
        .filter { highlightedIDs.contains($0.id) }
        .map { route in
            let start = namesByID[route.fromLocationID] ?? route.fromLocationID
            let end = namesByID[route.toLocationID] ?? route.toLocationID
            let owner = route.placedLink.flatMap { playersByID[$0.ownerID] }
            return (
                id: route.id,
                label: MapRouteAccessibility.label(
                    route: route, startName: start, endName: end,
                    currentEra: currentEra, ownerName: owner
                )
            )
        }
    return locations + routes
}
```

- [ ] **Step 6: Run focused map tests and verify GREEN**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=06658FF6-CF6B-423F-A101-3ADBEFF19C04' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests/GameMapSceneTests
```

Expected: all map scene tests pass, including the exact Chinese accessibility strings.

- [ ] **Step 7: Commit Task 4**

```bash
git -C /Users/didi/Desktop/Interview-learning add \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/MapRouteLegend.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/MapRouteEraStyle.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/GameMapView.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/GameMapSceneTests.swift
git -C /Users/didi/Desktop/Interview-learning commit -m "feat: add route era legend and labels"
```

### Task 5: Verify both eras and export visual evidence

**Files:**

- Modify: `IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift:3-18`
- Verify: `IndustrialCityBirmingham/Features/Map/*.swift`
- Verify: `IndustrialCityBirminghamTests/*.swift`

- [ ] **Step 1: Add a second landscape evidence test for the railway era**

Add beside `testRealFixtureLandscapeVisualEvidence`:

```swift
@MainActor
func testRailEraLandscapeVisualEvidence() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = XCUIApplication()
    app.launchArguments = ["-local-ui-fixture", "-rail-fixture", "-reduce-motion", "YES"]
    app.launch()
    XCTAssertTrue(app.otherElements["real.match"].waitForExistence(timeout: 5))
    XCUIDevice.shared.orientation = .landscapeLeft
    Thread.sleep(forTimeInterval: 2)
    XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "real-fixture-rail-era-landscape"
    attachment.lifetime = .keepAlways
    add(attachment)
}
```

- [ ] **Step 2: Run the complete unit suite serially**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=06658FF6-CF6B-423F-A101-3ADBEFF19C04' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests
```

Expected: all unit tests pass with zero failures.

- [ ] **Step 3: Run both landscape evidence tests and export their attachments**

```bash
result_dir=$(mktemp -d /tmp/route-era-results.XXXXXX)
attachment_dir=$(mktemp -d /tmp/route-era-attachments.XXXXXX)
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=06658FF6-CF6B-423F-A101-3ADBEFF19C04' \
  -parallel-testing-enabled NO \
  -resultBundlePath "$result_dir/route-era.xcresult" \
  -only-testing:IndustrialCityBirminghamUITests/FriendsPlayableUITests/testRealFixtureLandscapeVisualEvidence \
  -only-testing:IndustrialCityBirminghamUITests/FriendsPlayableUITests/testRailEraLandscapeVisualEvidence
xcrun xcresulttool export attachments \
  --path "$result_dir/route-era.xcresult" \
  --output-path "$attachment_dir"
find "$attachment_dir" -type f -name '*.png' -print
```

Expected: both UI tests pass and at least two PNG files are listed. Preserve the printed absolute paths for the manual handoff.

- [ ] **Step 4: Inspect both screenshots**

Open the two PNG paths printed in Step 3 and verify:

- 运河时代：`burton-on-trent-walsall` is a normal-weight teal solid line; the eight rail-only routes are visible but dim;
- 铁路时代：the single canal-only route is visible but dim; rail-only dashed routes are normal weight;
- dual-era routes retain teal outer and steel inner lines in both screenshots;
- the legend is fixed at the upper right and does not obscure primary controls;
- city labels, both rural breweries, route curves, owner colors, and selected-route glow remain legible.

- [ ] **Step 5: Confirm no image asset changed**

```bash
git -C /Users/didi/Desktop/Interview-learning diff --name-only b73ac24..HEAD -- \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Assets.xcassets
```

Expected: no output.

- [ ] **Step 6: Commit the UI evidence test**

```bash
git -C /Users/didi/Desktop/Interview-learning add \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift
git -C /Users/didi/Desktop/Interview-learning commit -m "test: capture both route era map states"
```

- [ ] **Step 7: Hand off the two screenshots for manual acceptance**

Report both absolute PNG paths and ask the user to compare the route-era distinction, dimming level, and legend placement. Do not claim visual acceptance until the user confirms it.
