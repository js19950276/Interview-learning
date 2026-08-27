# Legal Build Choices and Map Industry Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Only present industries that can legally be built with the selected card, and make each built industry type unmistakable on the map.

**Architecture:** Keep legality inside the authoritative `LegalActionQueryEngine` by filtering stack-top tiles through `BuildRules.legalBuildTargets`. Keep snapshot projection unchanged and enrich only the SpriteKit representation, because `MapIndustryPlacement.kind` already reaches the renderer.

**Tech Stack:** Swift 6, Swift Testing, SpriteKit, SwiftUI, Xcode/iOS simulators

---

### Task 1: Filter the first build-choice step by authoritative legality

**Files:**
- Modify: `IndustrialCityBirmingham/GameCore/Rules/LegalActionQueryEngine.swift`
- Test: `IndustrialCityBirminghamTests/BuildAndNetworkRulesTests.swift`

- [ ] **Step 1: Write the failing Kidderminster regression test**

Add a test that replaces the active player's hand with a `location-kidderminster` card, queries `.build` with no selections, resolves every `.industryTile` choice back to its stack-top tile, and asserts that the returned industry definition IDs are exactly `cotton-mill` and `coal-mine`. Also assert that every returned tile has a non-empty `legalBuildTargets` result.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:IndustrialCityBirminghamTests/BuildAndNetworkRulesTests/legalBuildQueryOnlyOffersIndustriesWithAValidTargetForTheSelectedLocationCard
```

Expected: FAIL because the initial response currently includes stack-top industries without a Kidderminster target.

- [ ] **Step 3: Implement the minimal query filter**

In the `tileIDs.isEmpty` branch, filter `player.industryStacks.compactMap(\.tiles.first)` with:

```swift
BuildRules.legalBuildTargets(
    actorID: actorID,
    cardID: cardID,
    tile: tile,
    state: state,
    catalog: catalog
).isEmpty == false
```

Then map the surviving tiles to the existing `LegalChoice` representation.

- [ ] **Step 4: Run the focused rule test and verify GREEN**

Run the command from Step 2. Expected: PASS.

### Task 2: Render a persistent, typed industry badge on the map

**Files:**
- Modify: `IndustrialCityBirmingham/Features/Map/MapNodeFactory.swift`
- Test: `IndustrialCityBirminghamTests/GameMapSceneTests.swift`

- [ ] **Step 1: Strengthen the existing map placement test**

Change the fixture placement to a coal mine and assert:

```swift
let industry = try #require(
    scene.childNode(withName: "//location:\(locationID)/industry:placed-coal")
)
#expect(industry.childNode(withName: "industry-kind")?.letLabelText == "煤")
#expect(industry.childNode(withName: "industry-detail")?.letLabelText == "L1·2")
#expect(industry.userData?["industryKind"] as? String == IndustryKind.coal.rawValue)
#expect(industry.userData?["industryName"] as? String == "煤矿")
```

Use an `SKLabelNode` cast in the actual test rather than introducing the illustrative `letLabelText` helper.

- [ ] **Step 2: Run the focused map test and verify RED**

Run:

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:IndustrialCityBirminghamTests/GameMapSceneTests/configureRendersPublicIndustryAndOwnedLinkMarkers
```

Expected: FAIL because no named kind/detail labels or industry semantic metadata exist.

- [ ] **Step 3: Add the compact visual mapping and badge contents**

Add private mappings in `MapNodeFactory`:

```swift
private static func industryGlyph(_ kind: IndustryKind) -> String {
    switch kind {
    case .cotton: "棉"
    case .manufacturer: "制"
    case .pottery: "陶"
    case .coal: "煤"
    case .iron: "铁"
    case .brewery: "酒"
    }
}

private static func industryName(_ kind: IndustryKind) -> String {
    switch kind {
    case .cotton: "棉纺厂"
    case .manufacturer: "制造厂"
    case .pottery: "陶器厂"
    case .coal: "煤矿"
    case .iron: "炼铁厂"
    case .brewery: "啤酒厂"
    }
}
```

Resize the badge to 28×28, add `industryKind` and `industryName` to `userData`, and replace the single `level·resource` label with:

```swift
let kindLabel = SKLabelNode(text: industryGlyph(placement.kind))
kindLabel.name = "industry-kind"

let detail = placement.resourceCount > 0
    ? "L\(placement.level)·\(placement.resourceCount)"
    : "L\(placement.level)"
let detailLabel = SKLabelNode(text: detail)
detailLabel.name = "industry-detail"
```

Position the type label in the upper half and the detail label in the lower half with contrasting text colors.

- [ ] **Step 4: Run the focused map test and verify GREEN**

Run the command from Step 2. Expected: PASS.

### Task 3: Regression verification and simulator handoff

**Files:**
- Verify: `IndustrialCityBirmingham/GameCore/Rules/LegalActionQueryEngine.swift`
- Verify: `IndustrialCityBirmingham/Features/Map/MapNodeFactory.swift`

- [ ] **Step 1: Run targeted test suites**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:IndustrialCityBirminghamTests/BuildAndNetworkRulesTests -only-testing:IndustrialCityBirminghamTests/GameMapSceneTests -only-testing:IndustrialCityBirminghamTests/RealMatchProjectionTests
```

Expected: all selected tests PASS.

- [ ] **Step 2: Run the complete serial unit suite**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
```

Expected: all unit tests PASS with zero failures.

- [ ] **Step 3: Build Debug and relaunch both manual-test simulators**

Build the app, install it on the existing iPhone and iPad devices, and launch bundle `com.didi.prototype.IndustrialCityBirmingham` with `-nearby-fixture-catalog`. Expected: both devices open on the app home screen and the nearby-room debug flow remains available.
