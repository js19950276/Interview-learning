# Active Turn Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every iPhone and iPad client immediately show whether it is the local player's turn or which named player it is waiting for.

**Architecture:** Add a pure presentation model that resolves the authoritative active player against the local player and centralizes Chinese copy, color, and shape vocabulary. Feed that model into a persistent header pill, stronger phone/tablet player-rail states, and a transient non-interactive notice driven only by active-player and synchronization transitions.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, XCTest UI tests, Xcode iOS Simulator.

---

## File Map

- Create `IndustrialCityBirmingham/Features/Match/ActiveTurnPresentation.swift`: pure active-turn copy and notice-trigger state.
- Create `IndustrialCityBirmingham/Features/Match/ActiveTurnViews.swift`: reusable header pill and transient notice SwiftUI views.
- Modify `IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift`: resolve local/active state, display the persistent and transient indicators, announce and haptically signal local turns.
- Modify `IndustrialCityBirmingham/Features/Match/PlayerRailView.swift`: identify the local player and strengthen current-player presentation for phone and tablet.
- Create `IndustrialCityBirminghamTests/ActiveTurnIndicatorTests.swift`: presentation, trigger, and accessibility regression tests.
- Modify `IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift`: persistent real-fixture assertions for the new status and player-rail semantics.

### Task 1: Pure Active-Turn Presentation and Trigger State

**Files:**
- Create: `IndustrialCityBirminghamTests/ActiveTurnIndicatorTests.swift`
- Create: `IndustrialCityBirmingham/Features/Match/ActiveTurnPresentation.swift`

- [ ] **Step 1: Write the failing presentation and trigger tests**

Create `IndustrialCityBirminghamTests/ActiveTurnIndicatorTests.swift` with tests that require the wished-for API:

```swift
import Testing
@testable import IndustrialCityBirmingham

struct ActiveTurnIndicatorTests {
    private let players = [
        PlayerSummary(
            id: "host", name: "host", color: .crimson, order: 1, spent: 0,
            isCurrent: true, isHost: true, isReady: true, isConnected: true
        ),
        PlayerSummary(
            id: "guest", name: "guest", color: .teal, order: 2, spent: 0,
            isCurrent: false, isHost: false, isReady: true, isConnected: true
        ),
    ]

    @Test func localTurnUsesDirectSecondPersonCopy() throws {
        let value = try #require(ActiveTurnPresentation.make(
            players: players, localPlayerID: "host"
        ))
        #expect(value.headerText == "轮到你 · host")
        #expect(value.noticeText == "轮到你了")
        #expect(value.isLocalPlayer)
        #expect(value.accessibilityLabel.contains("深红色"))
        #expect(value.accessibilityLabel.contains("三角形标记"))
    }

    @Test func remoteTurnAlwaysNamesThePlayerBeingWaitedFor() throws {
        let value = try #require(ActiveTurnPresentation.make(
            players: players, localPlayerID: "guest"
        ))
        #expect(value.headerText == "等待 host")
        #expect(value.noticeText == "现在轮到 host")
        #expect(!value.isLocalPlayer)
    }

    @Test func missingCurrentPlayerProducesNoPresentation() {
        #expect(ActiveTurnPresentation.make(
            players: players.map {
                var player = $0
                player.isCurrent = false
                return player
            },
            localPlayerID: "guest"
        ) == nil)
    }

    @Test func noticeTrackerIgnoresDuplicateSnapshotsAndRepeatsAfterRecovery() {
        var tracker = ActiveTurnNoticeTracker()
        #expect(tracker.consume(playerID: "host", isSynchronized: true))
        #expect(!tracker.consume(playerID: "host", isSynchronized: true))
        #expect(tracker.consume(playerID: "guest", isSynchronized: true))
        #expect(!tracker.consume(playerID: "guest", isSynchronized: false))
        #expect(tracker.consume(playerID: "guest", isSynchronized: true))
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests/ActiveTurnIndicatorTests
```

Expected: compilation fails because `ActiveTurnPresentation` and `ActiveTurnNoticeTracker` do not exist.

- [ ] **Step 3: Implement the minimal pure model**

Create `IndustrialCityBirmingham/Features/Match/ActiveTurnPresentation.swift`:

```swift
import Foundation

nonisolated struct ActiveTurnPresentation: Equatable, Sendable {
    let playerID: String
    let playerName: String
    let playerColor: PlayerColor
    let isLocalPlayer: Bool

    var headerText: String {
        isLocalPlayer ? "轮到你 · \(playerName)" : "等待 \(playerName)"
    }

    var noticeText: String {
        isLocalPlayer ? "轮到你了" : "现在轮到 \(playerName)"
    }

    var accessibilityLabel: String {
        "\(headerText)，\(playerColor.localizedName)，\(playerColor.localizedShapeName)"
    }

    static func make(players: [PlayerSummary], localPlayerID: String) -> Self? {
        guard let player = players.first(where: \.isCurrent) else { return nil }
        return .init(
            playerID: player.id,
            playerName: player.name,
            playerColor: player.color,
            isLocalPlayer: player.id == localPlayerID
        )
    }
}

nonisolated struct ActiveTurnNoticeTracker: Equatable, Sendable {
    private(set) var lastPresentedPlayerID: String?
    private(set) var wasSynchronized = false

    mutating func consume(playerID: String?, isSynchronized: Bool) -> Bool {
        guard isSynchronized, let playerID else {
            wasSynchronized = false
            return false
        }
        let shouldPresent = !wasSynchronized || lastPresentedPlayerID != playerID
        wasSynchronized = true
        lastPresentedPlayerID = playerID
        return shouldPresent
    }
}

nonisolated extension PlayerColor {
    var localizedName: String {
        switch self {
        case .amber: "琥珀色"
        case .crimson: "深红色"
        case .teal: "青绿色"
        case .violet: "紫罗兰色"
        }
    }

    var localizedShapeName: String {
        switch self {
        case .amber: "菱形标记"
        case .crimson: "三角形标记"
        case .teal: "圆形标记"
        case .violet: "方形标记"
        }
    }
}
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the Step 2 command again. Expected: all four tests pass.

- [ ] **Step 5: Commit the pure model**

```bash
git add Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Match/ActiveTurnPresentation.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/ActiveTurnIndicatorTests.swift
git commit -m "feat: model active turn presentation"
```

### Task 2: Strong Phone and Tablet Player-Rail States

**Files:**
- Modify: `IndustrialCityBirminghamTests/ActiveTurnIndicatorTests.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/PlayerRailView.swift`

- [ ] **Step 1: Write the failing local-player accessibility test**

Append:

```swift
@Test func playerRailNamesBothTheCurrentAndLocalPlayers() {
    let label = PlayerRailView.accessibilitySummary(
        players: players,
        showsColorAssistSymbols: true,
        localPlayerID: "guest"
    )
    #expect(label.contains("host，深红色，三角形标记"))
    #expect(label.contains("当前玩家"))
    #expect(label.contains("guest，青绿色，圆形标记"))
    #expect(label.contains("，你"))
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run the Task 1 Step 2 command. Expected: compilation fails because `accessibilitySummary` has no `localPlayerID` argument.

- [ ] **Step 3: Add local-player semantics and strong current-player styling**

Update `PlayerRailView` so its initializer accepts `localPlayerID: String? = nil`, passes it into accessibility helpers, and applies these concrete visual states:

```swift
let localPlayerID: String?

private func isLocal(_ player: PlayerSummary) -> Bool {
    player.id == localPlayerID
}

private func displayName(_ player: PlayerSummary) -> String {
    "\(player.order). \(player.name)\(isLocal(player) ? "（你）" : "")"
}
```

For tablet rows, replace the current play icon with `status("行动中", icon: "play.fill")`, use a 2 pt brass outline, brass background opacity `0.22`, and a static brass shadow. For phone cells, apply the background and outline to the entire cell, add a 3 pt leading brass bar for the current player, and show compact `行动` and `你` text badges independently.

Update the accessibility signature and label:

```swift
static func accessibilitySummary(
    players: [PlayerSummary],
    showsColorAssistSymbols: Bool,
    localPlayerID: String? = nil
) -> String

let local = player.id == localPlayerID ? "，你" : ""
return "顺序 \(player.order)，\(player.name)，\(player.color.localizedName)\(shape)，已花 \(player.spent) 英镑，\(ready)，\(connected)\(current)\(host)\(local)"
```

Use `player.color.localizedShapeName` for the shape phrase and remove the duplicated private color/shape-name switches.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the Task 1 Step 2 command. Expected: all five tests pass.

- [ ] **Step 5: Commit the player rail**

```bash
git add Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Match/PlayerRailView.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamTests/ActiveTurnIndicatorTests.swift
git commit -m "feat: strengthen active player rail state"
```

### Task 3: Persistent Header Pill and Transient Turn Notice

**Files:**
- Create: `IndustrialCityBirmingham/Features/Match/ActiveTurnViews.swift`
- Modify: `IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift`
- Modify: `IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift`

- [ ] **Step 1: Write the failing real-fixture UI test**

Add to `FriendsPlayableUITests`:

```swift
@MainActor
func testLocalUIFixtureMakesTheCurrentPlayerUnmistakable() {
    let app = XCUIApplication()
    app.launchArguments = ["-local-ui-fixture", "-reduce-motion", "YES"]
    app.launch()

    XCTAssertTrue(app.otherElements["real.match"].waitForExistence(timeout: 5))
    let status = app.descendants(matching: .any)["real.turn.status"]
    XCTAssertTrue(status.waitForExistence(timeout: 2))
    XCTAssertTrue(status.label.contains("轮到你"))
    XCTAssertTrue(status.label.contains("host"))

    let current = app.descendants(matching: .any)["match.player.host"]
    XCTAssertTrue(current.waitForExistence(timeout: 2))
    XCTAssertTrue(current.label.contains("当前玩家"))
    XCTAssertTrue(current.label.contains("你"))
}
```

Change the existing `real.turn` assertion to `real.turn.status`.

- [ ] **Step 2: Run the focused UI test and verify RED**

Run:

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamUITests/FriendsPlayableUITests/testLocalUIFixtureMakesTheCurrentPlayerUnmistakable
```

Expected: test fails because `real.turn.status` does not exist.

- [ ] **Step 3: Create the two reusable SwiftUI indicator views**

Create `IndustrialCityBirmingham/Features/Match/ActiveTurnViews.swift`:

```swift
import SwiftUI

struct ActiveTurnStatusView: View {
    let presentation: ActiveTurnPresentation

    var body: some View {
        Label(presentation.headerText, systemImage: presentation.playerColor.symbol)
            .font(.caption.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(BrassColor.coal.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background((presentation.isLocalPlayer ? BrassColor.brass : BrassColor.paper).color)
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(BrassColor.brass.color.opacity(0.7), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityIdentifier("real.turn.status")
    }
}

struct ActiveTurnNoticeView: View {
    let presentation: ActiveTurnPresentation
    let reduceMotion: Bool

    var body: some View {
        Label(presentation.noticeText, systemImage: presentation.playerColor.symbol)
            .font(BrassTypography.title)
            .foregroundStyle(BrassColor.paper.color)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(BrassColor.coal.color.opacity(0.95))
            .clipShape(Capsule())
            .overlay { Capsule().stroke(BrassColor.brass.color, lineWidth: 2) }
            .shadow(color: Color.black.opacity(0.45), radius: 14, y: 6)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
            .accessibilityIdentifier("real.turn.notice")
            .accessibilityHidden(true)
    }
}
```

- [ ] **Step 4: Integrate the presentation into the authoritative board**

In `AuthoritativeMatchBoardView`, add UIKit, the environment/state, and the hashable task key:

```swift
import SwiftUI
import UIKit

@Environment(MotionPreferences.self) private var preferences
@Environment(\.accessibilityReduceMotion) private var systemReduceMotion
@State private var activeTurnNotice: ActiveTurnPresentation?
@State private var activeTurnNoticeTracker = ActiveTurnNoticeTracker()

private struct ActiveTurnNoticeTaskID: Hashable {
    let activePlayerID: String?
    let isSynchronized: Bool
}
```

Inside the successful projection branch, resolve the presentation and task ID without including authoritative version or action number:

```swift
let activeTurn = ActiveTurnPresentation.make(
    players: state.players,
    localPlayerID: store.localPlayerID.rawValue
)
let noticeTaskID = ActiveTurnNoticeTaskID(
    activePlayerID: activeTurn?.playerID,
    isSynchronized: store.syncStatus == .synchronized
)

```

Insert `activeTurnNoticeLayer(metrics: metrics)` immediately after the current `GameMapView` modifier chain. Change the header call to `header(state: state, activeTurn: activeTurn, metrics: metrics)`. Keep confirmation, forced-sale, synchronization, and recovery overlays after the notice layer. Attach this task to the completed `ZStack`:

```swift
.task(id: noticeTaskID) {
    await presentActiveTurnNotice(activeTurn, taskID: noticeTaskID)
}
```

Update the player rail call and header signature/body:

```swift
PlayerRailView(
    players: state.players,
    metrics: metrics,
    localPlayerID: store.localPlayerID.rawValue
)

private func header(
    state: DemoMatchState,
    activeTurn: ActiveTurnPresentation?,
    metrics: MatchLayoutMetrics
) -> some View {
    VStack(spacing: 4) {
        HStack(spacing: 8) {
            Text("房间 \(store.roomID.rawValue)")
                .accessibilityIdentifier("real.room")
            if let activeTurn {
                ActiveTurnStatusView(presentation: activeTurn)
                    .layoutPriority(2)
            }
            Spacer(minLength: 4)
            Text("v\(store.version.rawValue) · \(store.syncStatus.rawValue)")
                .accessibilityIdentifier("real.sync")
        }
        .font(.caption2.bold())
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .foregroundStyle(BrassColor.paper.color)
        .padding(.horizontal, 8)

        MatchHeaderView(state: state)
    }
    .padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 8)
    .padding(.top, 4)
    .frame(maxHeight: .infinity, alignment: .top)
}
```

Add the map-centered layer and async presenter:

```swift
@ViewBuilder
private func activeTurnNoticeLayer(metrics: MatchLayoutMetrics) -> some View {
    if let activeTurnNotice {
        ActiveTurnNoticeView(
            presentation: activeTurnNotice,
            reduceMotion: preferences.reduceMotion || systemReduceMotion
        )
        .allowsHitTesting(false)
        .padding(.horizontal, max(metrics.leftRailWidth, metrics.rightRailWidth) + 8)
        .padding(.top, 52)
        .padding(.bottom, metrics.handHeight + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

@MainActor
private func presentActiveTurnNotice(
    _ presentation: ActiveTurnPresentation?,
    taskID: ActiveTurnNoticeTaskID
) async {
    let shouldPresent = activeTurnNoticeTracker.consume(
        playerID: taskID.activePlayerID,
        isSynchronized: taskID.isSynchronized
    )
    guard shouldPresent, let presentation else {
        if !taskID.isSynchronized { activeTurnNotice = nil }
        return
    }

    let reduceMotion = preferences.reduceMotion || systemReduceMotion
    withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.28, dampingFraction: 0.82)) {
        activeTurnNotice = presentation
    }
    UIAccessibility.post(notification: .announcement, argument: presentation.accessibilityLabel)
    if presentation.isLocalPlayer && preferences.isHapticsEnabled {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    do {
        try await Task<Never, Never>.sleep(for: .milliseconds(1_200))
    } catch {
        return
    }
    guard !Task.isCancelled else { return }
    withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.2)) {
        activeTurnNotice = nil
    }
}
```

Keep confirmation, forced-sale, synchronization, and recovery overlays after `activeTurnNoticeLayer` in the `ZStack`, so they retain higher visual priority.

- [ ] **Step 5: Run the focused UI test and verify GREEN**

Run the Step 2 command. Expected: the test passes and the persistent status says `轮到你 · host`.

- [ ] **Step 6: Commit the integrated indicator**

```bash
git add Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Match/ActiveTurnViews.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift \
  Brass-Birmingham/ui-prototype/IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift
git commit -m "feat: add linked active turn indicators"
```

### Task 4: Regression and Visual Verification

**Files:**
- Verify: `IndustrialCityBirmingham/Features/Match/*.swift`
- Verify: `IndustrialCityBirminghamTests/ActiveTurnIndicatorTests.swift`
- Verify: `IndustrialCityBirminghamUITests/FriendsPlayableUITests.swift`

- [ ] **Step 1: Run focused active-turn unit tests**

Run the Task 1 Step 2 command. Expected: all active-turn tests pass.

- [ ] **Step 2: Run the complete unit-test target**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests
```

Expected: the baseline 454 tests plus the new active-turn tests pass.

- [ ] **Step 3: Run the focused UI test on iPhone and iPad**

Run the Task 3 Step 2 command, then repeat it with destination `platform=iOS Simulator,name=IndustrialCity-iPad,OS=26.5`. Expected: both pass.

- [ ] **Step 4: Capture iPhone and iPad real-fixture screenshots**

Run `FriendsPlayableUITests/testRealFixtureLandscapeVisualEvidence` on both simulator destinations. Inspect the attachments to confirm the status pill is readable, the active player rail is obvious, no route legend is covered, and the map remains usable.

- [ ] **Step 5: Run the two-simulator room test**

```bash
bash scripts/run_two_simulator_room_test.sh
```

Expected: host and guest converge on the same active player and the test exits successfully.

- [ ] **Step 6: Check the final diff and commit any verification-only test adjustment**

```bash
git diff --check
git status --short
```

If no verification adjustment was needed, do not create an empty commit. If a test-only adjustment was required, stage only the touched active-turn files and commit with `test: verify active turn indicators`.
