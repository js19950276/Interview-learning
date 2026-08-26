# iPhone Collapsible Rails and Map Viewport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the authoritative iPhone match rails toggleable and let the map pan its bottom edge above the hand without changing iPad rail behavior.

**Architecture:** Add explicit occlusion insets to the pure map viewport math, propagate them from shared match layout metrics into `GameMapView`, and reuse `MatchInteractionReducer.overlay` for the two phone drawers. Keep expanded drawers transient so toggling them never changes camera bounds, and leave iPad on the existing permanent rails.

**Tech Stack:** Swift 6, SwiftUI, SpriteKit, Swift Testing, XCTest/XCUITest, Xcode iOS simulator

---

### Task 1: Make camera bounds aware of the unobscured viewport

**Files:**
- Modify: `IndustrialCityBirmingham/Features/Map/GameMapScene.swift`
- Test: `IndustrialCityBirminghamTests/GameMapSceneTests.swift`

- [ ] **Step 1: Write failing inset and bottom-edge tests**

Add tests that express the new pure API before production code exists:

```swift
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
    let scene = GameMapScene()
    let camera = try #require(scene.camera)
    scene.updateViewport(size: CGSize(width: 852, height: 393), insets: insets)

    scene.updateCamera(
        scale: MapViewportMetrics.minimumZoom,
        translation: CGPoint(x: 0, y: -100_000)
    )

    let clearRect = scene.viewportMetrics.unobscuredSceneRect(cameraCenter: camera.position)
    #expect(abs(clearRect.minY) < 0.0001)
    #expect(camera.position.y < GameMapScene.logicalSize.height / 2)

    let state = DemoFixture.match(playerCount: 4)
    let gloucester = try #require(state.locations.first { $0.id == "gloucester" })
    scene.configure(state: state, highlightedIDs: [gloucester.id])
    let gloucesterPoint = MapNodeFactory.point(for: gloucester, in: GameMapScene.logicalSize)
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
    #expect(legacy.clampedCameraCenter(CGPoint(x: -10_000, y: 10_000))
        == explicitZero.clampedCameraCenter(CGPoint(x: -10_000, y: 10_000)))
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test \
  -project IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=942E54C1-E4A7-4E47-AFBE-E21B724B0F5E' \
  -derivedDataPath /tmp/industrialcity-rail-drawers \
  -only-testing:IndustrialCityBirminghamTests/GameMapSceneTests
```

Expected: FAIL because `MapViewportInsets`, `viewportInsets`, `unobscuredViewportRect`, the inset-aware `updateViewport`, and `unobscuredSceneRect` do not exist.

- [ ] **Step 3: Implement the minimal inset-aware viewport math**

In `GameMapScene.swift`, add a nonisolated value type and extend `MapViewportMetrics`:

```swift
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
        return .init(top: top, leading: leading, bottom: bottom, trailing: trailing)
    }
}
```

Give `MapViewportMetrics.init` a defaulted `viewportInsets: MapViewportInsets = .zero`, store the clamped value, and derive:

```swift
var unobscuredViewportRect: CGRect {
    CGRect(
        x: viewportInsets.leading,
        y: viewportInsets.top,
        width: max(viewportSize.width - viewportInsets.leading - viewportInsets.trailing, 1),
        height: max(viewportSize.height - viewportInsets.top - viewportInsets.bottom, 1)
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
```

Replace `clampedCameraCenter` and add the scene-rect helper:

```swift
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
```

Update the scene entry point while preserving source compatibility:

```swift
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
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Task 1 command again. Expected: all `GameMapSceneTests` pass, including existing extreme translation and latent-offset tests.

- [ ] **Step 5: Commit Task 1**

```bash
git add Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/GameMapScene.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/GameMapSceneTests.swift
git commit -m "fix: account for covered map viewport"
```

### Task 2: Feed iPhone-only occlusion insets through the match layout

**Files:**
- Modify: `IndustrialCityBirmingham/Features/Match/MatchLayoutMetrics.swift`
- Modify: `IndustrialCityBirmingham/Features/Map/GameMapView.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift`
- Test: `IndustrialCityBirminghamTests/MatchLayoutMetricsTests.swift`

- [ ] **Step 1: Write failing layout tests**

```swift
@Test func phoneMapViewportInsetsClearHeaderHandAndMiniRails() {
    let metrics = MatchLayoutMetrics(
        viewport: CGSize(width: 852, height: 393),
        safeAreaTrailing: 59
    )

    #expect(metrics.mapViewportInsets == MapViewportInsets(
        top: 0, leading: 44, bottom: 92, trailing: 103
    ))
}

@Test func tabletKeepsLegacyZeroMapViewportInsets() {
    let metrics = MatchLayoutMetrics(
        viewport: CGSize(width: 1_194, height: 834),
        safeAreaTrailing: 24
    )

    #expect(metrics.mapViewportInsets == .zero)
}
```

- [ ] **Step 2: Run layout tests and verify RED**

Run:

```bash
xcodebuild test \
  -project IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=942E54C1-E4A7-4E47-AFBE-E21B724B0F5E' \
  -derivedDataPath /tmp/industrialcity-rail-drawers \
  -only-testing:IndustrialCityBirminghamTests/MatchLayoutMetricsTests
```

Expected: FAIL because `mapViewportInsets` is missing.

- [ ] **Step 3: Implement layout mapping and view propagation**

Add to `MatchLayoutMetrics`:

```swift
var mapViewportInsets: MapViewportInsets {
    guard formFactor == .phone else { return .zero }
    return MapViewportInsets(
        // The outer layout already places GameMapView below the header.
        top: 0,
        leading: leftRailWidth,
        bottom: handHeight,
        trailing: rightRailWidth + safeAreaTrailing
    )
}
```

Add `viewportInsets: MapViewportInsets = .zero` to `GameMapView`, store it from the initializer, and pass it to every `scene.updateViewport` call. Add this update path:

```swift
.onChange(of: viewportInsets) { _, newInsets in
    let appliedTranslation = scene.updateViewport(
        size: proxy.size,
        insets: newInsets
    )
    if !isDragging {
        committedTranslation = appliedTranslation
    }
    updateCamera()
}
```

In `AuthoritativeMatchBoardView`, pass the shared layout value:

```swift
GameMapView(
    state: state,
    highlightedIDs: highlightedIDs,
    onTargetTap: selectMapTarget,
    onBackgroundTap: interaction.dismissOverlay,
    legendInsets: MapLegendInsets(
        top: 0,
        trailing: metrics.mapLegendInsets.trailing
    ),
    viewportInsets: metrics.mapViewportInsets
)
```

- [ ] **Step 4: Run layout and map tests and verify GREEN**

Run both focused test suites. Expected: all tests pass and all pre-existing zero-inset call sites compile unchanged.

- [ ] **Step 5: Commit Task 2**

```bash
git add Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Match/MatchLayoutMetrics.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/GameMapView.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/MatchLayoutMetricsTests.swift
git commit -m "feat: expose the unobscured iphone map"
```

### Task 3: Add authoritative iPhone rail toggles and drawers

**Files:**
- Create: `IndustrialCityBirmingham/Features/Match/AuthoritativeRailDrawers.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift`
- Modify: `IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift`

- [ ] **Step 1: Write failing iPhone drawer UI tests**

Add this helper and test:

```swift
@MainActor
private func launchLocalFixture() -> XCUIApplication {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = XCUIApplication()
    app.launchArguments = ["-local-ui-fixture", "-reduce-motion", "YES"]
    app.launch()
    XCTAssertTrue(app.otherElements["real.match"].waitForExistence(timeout: 5))
    XCUIDevice.shared.orientation = .landscapeLeft
    return app
}

@MainActor
func testPhoneAuthoritativeRailsToggleAndStayMutuallyExclusive() {
    let app = launchLocalFixture()
    XCTAssertLessThan(app.windows.firstMatch.frame.width, 1_000)

    let playerToggle = app.buttons["real.playerRail.toggle"]
    let industryToggle = app.buttons["real.industryRail.toggle"]
    XCTAssertTrue(playerToggle.waitForExistence(timeout: 2))
    XCTAssertEqual(playerToggle.value as? String, "已收起")

    playerToggle.tap()
    XCTAssertTrue(app.descendants(matching: .any)["overlay.playerRail"].waitForExistence(timeout: 1))
    XCTAssertEqual(playerToggle.value as? String, "已展开")

    industryToggle.tap()
    XCTAssertTrue(app.descendants(matching: .any)["overlay.playerRail"].waitForNonExistence(timeout: 1))
    XCTAssertTrue(app.descendants(matching: .any)["overlay.industryRail"].waitForExistence(timeout: 1))

    industryToggle.tap()
    XCTAssertTrue(app.descendants(matching: .any)["overlay.industryRail"].waitForNonExistence(timeout: 1))
    XCTAssertEqual(industryToggle.value as? String, "已收起")
}

@MainActor
func testTabletAuthoritativeRailsRemainPermanent() {
    let app = launchLocalFixture()
    XCTAssertGreaterThanOrEqual(app.windows.firstMatch.frame.width, 1_000)
    XCTAssertFalse(app.buttons["real.playerRail.toggle"].exists)
    XCTAssertFalse(app.buttons["real.industryRail.toggle"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["match.playerRail.content"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["industry.flip.industry-cotton"].exists)
}
```

- [ ] **Step 2: Run the iPhone test and verify RED**

Run:

```bash
xcodebuild test \
  -project IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=942E54C1-E4A7-4E47-AFBE-E21B724B0F5E' \
  -derivedDataPath /tmp/industrialcity-rail-drawers \
  -only-testing:IndustrialCityBirminghamUITests/FriendsPlayableUITests/testPhoneAuthoritativeRailsToggleAndStayMutuallyExclusive
```

Expected: FAIL because the toggle buttons and authoritative drawer overlays do not exist.

- [ ] **Step 3: Implement drawer views**

Create `AuthoritativeRailDrawers.swift`:

```swift
import SwiftUI

struct AuthoritativePlayerDrawer: View {
    let players: [PlayerSummary]
    let localPlayerID: String
    let showsColorAssistSymbols: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("玩家顺序与花费")
                    .font(BrassTypography.title)
                    .foregroundStyle(BrassColor.brass.color)

                ForEach(players) { player in
                    HStack(spacing: 8) {
                        Image(systemName: showsColorAssistSymbols ? player.color.symbol : "circle.fill")
                            .frame(width: 24)
                            .foregroundStyle(tint(player.color))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(player.order). \(player.name)\(player.id == localPlayerID ? "（你）" : "")")
                                .font(BrassTypography.label)
                            HStack(spacing: 6) {
                                if player.isCurrent { Label("行动中", systemImage: "play.fill") }
                                if player.isHost { Label("主机", systemImage: "crown.fill") }
                                Label(player.isConnected ? "在线" : "离线",
                                      systemImage: player.isConnected ? "wifi" : "wifi.slash")
                            }
                            .font(.caption2)
                        }
                        Spacer(minLength: 0)
                        Text("£\(player.spent)").font(BrassTypography.number)
                    }
                    .foregroundStyle(BrassColor.paper.color)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
                    .background(player.isCurrent
                        ? BrassColor.brass.color.opacity(0.22)
                        : BrassColor.iron.color.opacity(0.24))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(PlayerRailView.accessibilitySummary(
                        players: [player],
                        showsColorAssistSymbols: showsColorAssistSymbols,
                        localPlayerID: localPlayerID
                    ))
                    .accessibilityIdentifier("drawer.player.\(player.id)")
                }
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
        .background(BrassColor.coal.color.opacity(0.95))
        .overlay(alignment: .trailing) {
            Rectangle().fill(BrassColor.brass.color.opacity(0.65)).frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overlay.playerRail")
    }

    private func tint(_ color: PlayerColor) -> Color {
        switch color {
        case .amber: BrassColor.brass.color
        case .crimson: BrassColor.danger.color
        case .teal: Color(red: 0.20, green: 0.67, blue: 0.67)
        case .violet: Color(red: 0.61, green: 0.45, blue: 0.78)
        }
    }
}

struct AuthoritativeIndustryDrawer: View {
    let industries: [IndustrySummary]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("产业板块")
                    .font(BrassTypography.title)
                    .foregroundStyle(BrassColor.brass.color)

                ForEach(industries) { industry in
                    HStack(spacing: 8) {
                        Image(systemName: industry.kind.symbol).frame(width: 24)
                        Text(name(industry.kind)).font(BrassTypography.label)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("L\(industry.level) · £\(industry.cost)")
                                .font(BrassTypography.number)
                            Text(industry.isAvailable ? "可用" : "已用").font(.caption2)
                        }
                    }
                    .foregroundStyle(BrassColor.paper.color)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
                    .background(BrassColor.iron.color.opacity(industry.isAvailable ? 0.32 : 0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(name(industry.kind))，等级 \(industry.level)，费用 \(industry.cost) 英镑，\(industry.isAvailable ? "可用" : "不可用")")
                    .accessibilityIdentifier("drawer.industry.\(industry.id)")
                }
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
        .background(BrassColor.coal.color.opacity(0.95))
        .overlay(alignment: .leading) {
            Rectangle().fill(BrassColor.brass.color.opacity(0.65)).frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overlay.industryRail")
    }

    private func name(_ kind: IndustryKind) -> String {
        switch kind {
        case .cotton: "棉纺厂"
        case .manufacturer: "制造厂"
        case .pottery: "陶器厂"
        case .coal: "煤矿"
        case .iron: "炼铁厂"
        case .brewery: "啤酒厂"
        }
    }
}
```

- [ ] **Step 4: Wire toggles and transient drawer layer**

In `AuthoritativeMatchBoardView`:

- wrap each iPhone mini rail in a plain button;
- call `interaction.toggleOverlay(.playerRail/.industryRail)`;
- expose labels and `已展开/已收起` values through `real.playerRail.toggle` and `real.industryRail.toggle`;
- render the matching authoritative drawer at `MatchInteractionReducer.drawerWidth(viewportWidth:)`;
- keep iPad branches unchanged;
- apply `.transition(.opacity)` when reduced motion is active, otherwise combine opacity with movement from the matching edge;
- keep mini rails above drawers so the same button remains tappable for closing.

- [ ] **Step 5: Run the iPhone and iPad UI tests and verify GREEN**

Run the new toggle test on the iPhone, then the tablet guard test on simulator `06658FF6-CF6B-423F-A101-3ADBEFF19C04`. Expected: iPhone drawers toggle and are mutually exclusive; iPad shows no toggle controls and retains permanent rails.

- [ ] **Step 6: Commit Task 3**

```bash
git add Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Match/AuthoritativeRailDrawers.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift
git commit -m "feat: toggle iphone match rails"
```

### Task 4: Prove bottom-map reachability and run regression evidence

**Files:**
- Modify: `IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift`

- [ ] **Step 1: Add an iPhone interaction/visual regression test**

Add this test:

```swift
@MainActor
func testPhoneMapPansAndExpandedDrawersStayClearOfTheHand() {
    let app = launchLocalFixture()
    XCTAssertLessThan(app.windows.firstMatch.frame.width, 1_000)

    let map = app.descendants(matching: .any)["match.map"]
    let hand = app.descendants(matching: .any)["real.hand"]
    XCTAssertTrue(map.waitForExistence(timeout: 2))
    XCTAssertTrue(hand.exists)

    let start = map.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.68))
    let end = map.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.24))
    start.press(forDuration: 0.1, thenDragTo: end)
    XCTAssertTrue(map.isHittable)

    let panned = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    panned.name = "iphone-map-panned-above-hand"
    panned.lifetime = .keepAlways
    add(panned)

    app.buttons["real.playerRail.toggle"].tap()
    let playerDrawer = app.descendants(matching: .any)["overlay.playerRail"]
    XCTAssertTrue(playerDrawer.waitForExistence(timeout: 1))
    XCTAssertGreaterThanOrEqual(playerDrawer.frame.minY, 52)
    XCTAssertLessThanOrEqual(playerDrawer.frame.maxY, hand.frame.minY + 1)

    let players = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    players.name = "iphone-player-drawer"
    players.lifetime = .keepAlways
    add(players)

    app.buttons["real.industryRail.toggle"].tap()
    let industryDrawer = app.descendants(matching: .any)["overlay.industryRail"]
    XCTAssertTrue(industryDrawer.waitForExistence(timeout: 1))
    XCTAssertGreaterThanOrEqual(industryDrawer.frame.minY, 52)
    XCTAssertLessThanOrEqual(industryDrawer.frame.maxY, hand.frame.minY + 1)

    let industries = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    industries.name = "iphone-industry-drawer"
    industries.lifetime = .keepAlways
    add(industries)
}
```

The map-camera unit test from Task 1 proves the bottom Gloucester node lies inside the unobscured scene rectangle and remains target-resolvable at the bottom camera limit; this UI test proves the real drag gesture remains active and the overlay geometry matches the hand boundary.

- [ ] **Step 2: Run the new test and inspect all screenshot attachments**

Export the `.xcresult` attachments with `xcrun xcresulttool export attachments`, then inspect the iPhone images for:

- bottom cities above the hand after panning;
- drawer top and bottom edges clear of the header and hand;
- mini toggle buttons still visible while a drawer is open;
- no overlap with the route-era legend or turn status.

- [ ] **Step 3: Run full automated regression**

Run:

```bash
xcodebuild test \
  -project IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=942E54C1-E4A7-4E47-AFBE-E21B724B0F5E' \
  -derivedDataPath /tmp/industrialcity-rail-drawers \
  -only-testing:IndustrialCityBirminghamTests

bash scripts/run_two_simulator_room_test.sh
```

Also rerun the focused authoritative UI suite on iPhone and iPad.

- [ ] **Step 4: Check the diff and request independent review**

Run `git diff --check`, inspect the scoped diff and status, and request a code review against the design and this plan. Fix all Critical or Important findings with a new RED/GREEN cycle.

- [ ] **Step 5: Commit final test refinements**

```bash
git add Brass-Birmingham/ui-prototype/IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift
git commit -m "test: verify iphone map reachability"
```
