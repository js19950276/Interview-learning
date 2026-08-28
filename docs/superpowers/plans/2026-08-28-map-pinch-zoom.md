# Map Pinch Zoom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Brass match map reliably zoom around the two-finger pinch anchor on iPhone and iPad without adding visible zoom controls.

**Architecture:** Keep `GameMapScene` authoritative for SpriteKit camera bounds. Add a pure `MapPinchZoom` projection that calculates semantic zoom and the camera translation needed to preserve the scene point under the pinch anchor; wire it into `GameMapView` and expose the current zoom as an accessibility value for deterministic UI verification.

**Tech Stack:** Swift 6, SwiftUI `MagnifyGesture`, SpriteKit `SKCameraNode`, Swift Testing, XCTest UI testing, Xcode 26.5 simulator.

---

## File map

- Create `Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/MapPinchZoom.swift`: pure zoom/anchor projection.
- Create `Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/MapPinchZoomTests.swift`: zoom clamping and anchor-preservation unit tests.
- Modify `Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/GameMapView.swift`: gesture lifecycle, camera application, and accessibility zoom state.
- Modify `Brass-Birmingham/ui-prototype/IndustrialCityBirminghamUITests/AppSmokeUITests.swift`: dedicated iPhone/iPad pinch behavior verification.

### Task 1: Pure anchored-zoom projection

**Files:**
- Create: `Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/MapPinchZoomTests.swift`
- Create: `Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/MapPinchZoom.swift`

- [ ] **Step 1: Write failing anchor and clamp tests**

```swift
import CoreGraphics
import Testing
@testable import IndustrialCityBirmingham

@MainActor
struct MapPinchZoomTests {
    @Test func zoomKeepsTheScenePointUnderAnOffCenterAnchorStable() {
        let viewport = CGSize(width: 852, height: 393)
        let anchor = CGPoint(x: 690, y: 92)
        let startingTranslation = CGPoint(x: 120, y: -80)
        let startingMetrics = MapViewportMetrics(
            logicalSize: GameMapScene.logicalSize,
            viewportSize: viewport,
            semanticZoom: 1,
            viewportInsets: .init(top: 76, leading: 44, bottom: 92, trailing: 44)
        )

        let projection = MapPinchZoom.projection(
            startingZoom: 1,
            magnification: 1.8,
            anchorInView: anchor,
            startingTranslation: startingTranslation,
            metrics: startingMetrics
        )
        let zoomedMetrics = MapViewportMetrics(
            logicalSize: startingMetrics.logicalSize,
            viewportSize: viewport,
            semanticZoom: projection.semanticZoom,
            viewportInsets: startingMetrics.viewportInsets
        )

        let before = scenePoint(
            under: anchor,
            translation: startingTranslation,
            metrics: startingMetrics
        )
        let after = scenePoint(
            under: anchor,
            translation: projection.translation,
            metrics: zoomedMetrics
        )

        #expect(abs(before.x - after.x) < 0.0001)
        #expect(abs(before.y - after.y) < 0.0001)
    }

    @Test(arguments: [
        (0.01, MapViewportMetrics.minimumZoom),
        (100.0, MapViewportMetrics.maximumZoom)
    ])
    func zoomClampsToSupportedBounds(magnification: CGFloat, expected: CGFloat) {
        let metrics = MapViewportMetrics(
            logicalSize: GameMapScene.logicalSize,
            viewportSize: CGSize(width: 1_366, height: 1_024),
            semanticZoom: 1
        )

        let projection = MapPinchZoom.projection(
            startingZoom: 1,
            magnification: magnification,
            anchorInView: CGPoint(x: 683, y: 512),
            startingTranslation: .zero,
            metrics: metrics
        )

        #expect(projection.semanticZoom == expected)
    }

    private func scenePoint(
        under viewPoint: CGPoint,
        translation: CGPoint,
        metrics: MapViewportMetrics
    ) -> CGPoint {
        let viewportCenter = CGPoint(
            x: metrics.viewportSize.width / 2,
            y: metrics.viewportSize.height / 2
        )
        let mapCenter = CGPoint(
            x: metrics.logicalSize.width / 2,
            y: metrics.logicalSize.height / 2
        )
        return CGPoint(
            x: mapCenter.x + translation.x
                + (viewPoint.x - viewportCenter.x) * metrics.sceneUnitsPerPoint,
            y: mapCenter.y + translation.y
                - (viewPoint.y - viewportCenter.y) * metrics.sceneUnitsPerPoint
        )
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test \
  -project Brass-Birmingham/ui-prototype/IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=942E54C1-E4A7-4E47-AFBE-E21B724B0F5E' \
  -only-testing:IndustrialCityBirminghamTests/MapPinchZoomTests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because `MapPinchZoom` does not exist.

- [ ] **Step 3: Add the minimal pure projection**

```swift
import CoreGraphics

struct MapPinchZoomProjection: Equatable, Sendable {
    let semanticZoom: CGFloat
    let translation: CGPoint
}

enum MapPinchZoom {
    static func projection(
        startingZoom: CGFloat,
        magnification: CGFloat,
        anchorInView: CGPoint,
        startingTranslation: CGPoint,
        metrics: MapViewportMetrics
    ) -> MapPinchZoomProjection {
        let startMetrics = MapViewportMetrics(
            logicalSize: metrics.logicalSize,
            viewportSize: metrics.viewportSize,
            semanticZoom: startingZoom,
            viewportInsets: metrics.viewportInsets
        )
        let targetZoom = min(
            max(startMetrics.semanticZoom * magnification, MapViewportMetrics.minimumZoom),
            MapViewportMetrics.maximumZoom
        )
        let targetMetrics = MapViewportMetrics(
            logicalSize: metrics.logicalSize,
            viewportSize: metrics.viewportSize,
            semanticZoom: targetZoom,
            viewportInsets: metrics.viewportInsets
        )
        let viewportCenter = CGPoint(
            x: metrics.viewportSize.width / 2,
            y: metrics.viewportSize.height / 2
        )
        let sceneUnitsDelta = startMetrics.sceneUnitsPerPoint - targetMetrics.sceneUnitsPerPoint

        return MapPinchZoomProjection(
            semanticZoom: targetZoom,
            translation: CGPoint(
                x: startingTranslation.x
                    + (anchorInView.x - viewportCenter.x) * sceneUnitsDelta,
                y: startingTranslation.y
                    - (anchorInView.y - viewportCenter.y) * sceneUnitsDelta
            )
        )
    }
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the command from Step 2. Expected: `MapPinchZoomTests` passes.

- [ ] **Step 5: Commit the pure projection**

```bash
git add \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/MapPinchZoom.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/MapPinchZoomTests.swift
git commit -m "feat: project map zoom around pinch anchor"
```

### Task 2: Wire the pinch lifecycle into the map view

**Files:**
- Modify: `Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/GameMapView.swift`
- Modify: `Brass-Birmingham/ui-prototype/IndustrialCityBirminghamUITests/AppSmokeUITests.swift`

- [ ] **Step 1: Add a dedicated failing UI test**

Add this test to `AppSmokeUITests` without using the older shell-bounds assertions:

```swift
@MainActor
func testMapPinchChangesReportedZoomInAndOut() throws {
    XCUIDevice.shared.orientation = .landscapeRight
    let app = launchApp(arguments: ["-fixture", "players4"])
    XCUIDevice.shared.orientation = .landscapeRight

    let map = app.descendants(matching: .any)["match.map"]
    XCTAssertTrue(map.waitForExistence(timeout: 5))
    XCTAssertEqual(map.value as? String, "缩放 0.75 倍")

    map.pinch(withScale: 1.6, velocity: 1)
    let zoomedIn = try XCTUnwrap(map.value as? String)
    XCTAssertNotEqual(zoomedIn, "缩放 0.75 倍")

    map.pinch(withScale: 0.2, velocity: -1)
    XCTAssertEqual(map.value as? String, "缩放 0.75 倍")
}
```

- [ ] **Step 2: Run the UI test and verify RED**

Run:

```bash
xcodebuild test \
  -project Brass-Birmingham/ui-prototype/IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=942E54C1-E4A7-4E47-AFBE-E21B724B0F5E' \
  -only-testing:IndustrialCityBirminghamUITests/AppSmokeUITests/testMapPinchChangesReportedZoomInAndOut \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Expected: the initial equality fails because `match.map` does not report a zoom value.

- [ ] **Step 3: Track the live camera translation and pinch anchor**

In `GameMapView`, add:

```swift
@State private var appliedTranslation: CGPoint = .zero
@State private var pinchStartTranslation: CGPoint?
@State private var pinchAnchor: CGPoint?
```

Replace the existing drag and magnify handlers with these versions. The drag handler ignores two-finger movement while a pinch is active. The magnify handler captures `appliedTranslation` and `value.startLocation` once, clears transient drag movement, and computes every frame from the same start state:

```swift
private var dragGesture: some Gesture {
    DragGesture()
        .onChanged { value in
            guard pinchStartTranslation == nil else { return }
            if panSignpost == nil {
                panSignpost = PrototypeSignpost.begin(.mapPanZoom)
            }
            isDragging = true
            dragTranslation = value.translation
            updateCamera()
        }
        .onEnded { value in
            guard pinchStartTranslation == nil else {
                dragTranslation = .zero
                isDragging = false
                panSignpost?.end()
                panSignpost = nil
                return
            }
            let sceneTranslation = scene.viewportMetrics.sceneTranslation(
                forDrag: value.translation
            )
            let proposal = CGPoint(
                x: committedTranslation.x + sceneTranslation.x,
                y: committedTranslation.y + sceneTranslation.y
            )
            appliedTranslation = scene.updateCamera(
                scale: currentSemanticZoom,
                translation: proposal
            )
            committedTranslation = appliedTranslation
            dragTranslation = .zero
            isDragging = false
            panSignpost?.end()
            panSignpost = nil
        }
}

private var magnifyGesture: some Gesture {
    MagnifyGesture()
        .onChanged { value in
            if zoomSignpost == nil {
                zoomSignpost = PrototypeSignpost.begin(.mapPanZoom)
            }
            if pinchStartTranslation == nil {
                pinchStartTranslation = appliedTranslation
                pinchAnchor = value.startLocation
                dragTranslation = .zero
                isDragging = false
            }
            gestureScale = value.magnification
            updateCamera()
        }
        .onEnded { value in
            gestureScale = value.magnification
            updateCamera()
            committedScale = currentSemanticZoom
            committedTranslation = appliedTranslation
            gestureScale = 1
            pinchStartTranslation = nil
            pinchAnchor = nil
            updateCamera()
            zoomSignpost?.end()
            zoomSignpost = nil
        }
}
```

In `updateCamera`, choose the anchored projection while a pinch is active:

```swift
let currentScale = clampedScale(committedScale * gestureScale)
let proposedTranslation: CGPoint
if let pinchStartTranslation, let pinchAnchor {
    proposedTranslation = MapPinchZoom.projection(
        startingZoom: committedScale,
        magnification: gestureScale,
        anchorInView: pinchAnchor,
        startingTranslation: pinchStartTranslation,
        metrics: scene.viewportMetrics
    ).translation
} else {
    let currentDrag = scene.viewportMetrics.sceneTranslation(forDrag: dragTranslation)
    proposedTranslation = CGPoint(
        x: committedTranslation.x + currentDrag.x,
        y: committedTranslation.y + currentDrag.y
    )
}
appliedTranslation = scene.updateCamera(
    scale: currentScale,
    translation: proposedTranslation
)
if !isDragging && pinchStartTranslation == nil {
    committedTranslation = appliedTranslation
}
```

In both viewport-change handlers and `synchronizeScene`, assign the canonical return value to the state property and only overwrite `committedTranslation` when neither drag nor pinch is active:

```swift
appliedTranslation = scene.updateViewport(
    size: viewportSize,
    insets: viewportInsets
)
if !isDragging && pinchStartTranslation == nil {
    committedTranslation = appliedTranslation
}
```

- [ ] **Step 4: Expose the semantic zoom to accessibility**

On the `match.map` accessibility element add:

```swift
.accessibilityValue(String(format: "缩放 %.2f 倍", currentSemanticZoom))
```

and define:

```swift
private var currentSemanticZoom: CGFloat {
    clampedScale(committedScale * gestureScale)
}
```

- [ ] **Step 5: Run the dedicated UI test and verify GREEN**

Run the command from Step 2. Expected: the zoom value starts at `0.75`, rises after zoom-in, and returns to `0.75` after zoom-out.

- [ ] **Step 6: Run focused map unit and UI regressions**

```bash
xcodebuild test \
  -project Brass-Birmingham/ui-prototype/IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=942E54C1-E4A7-4E47-AFBE-E21B724B0F5E' \
  -only-testing:IndustrialCityBirminghamTests/GameMapSceneTests \
  -only-testing:IndustrialCityBirminghamTests/MapPinchZoomTests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Expected: all selected map tests pass.

- [ ] **Step 7: Commit the gesture integration**

```bash
git add \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Map/GameMapView.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamUITests/AppSmokeUITests.swift
git commit -m "fix: make map pinch zoom observable and anchored"
```

### Task 3: Full verification and two-device acceptance

**Files:**
- Verify only; no production changes expected.

- [ ] **Step 1: Run the complete unit suite serially**

```bash
xcodebuild test \
  -project Brass-Birmingham/ui-prototype/IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,id=942E54C1-E4A7-4E47-AFBE-E21B724B0F5E' \
  -only-testing:IndustrialCityBirminghamTests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Expected: the full unit suite passes with no failures.

- [ ] **Step 2: Run the dedicated pinch UI test on iPhone and iPad**

Run the Task 2 UI command once with iPhone destination `942E54C1-E4A7-4E47-AFBE-E21B724B0F5E`, then again with iPad destination `06658FF6-CF6B-423F-A101-3ADBEFF19C04`.

Expected: both devices pass zoom-in and zoom-out assertions.

- [ ] **Step 3: Build Release for the simulator**

```bash
xcodebuild build \
  -project Brass-Birmingham/ui-prototype/IndustrialCityBirmingham.xcodeproj \
  -scheme IndustrialCityBirmingham \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Inspect the final diff and worktree**

```bash
git diff --check
git status --short
git log -3 --oneline --decorate
```

Expected: no whitespace errors and no unexpected uncommitted files.

- [ ] **Step 5: Confirm the committed plan is present in history**

```bash
git log --oneline -- docs/superpowers/plans/2026-08-28-map-pinch-zoom.md
```
