# Retry Persistence Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a real `重试保存` control that safely retries the current host or guest snapshot without replaying a gameplay action.

**Architecture:** Make `SessionCoordinator.retryPersistence()` role-aware and keep it serialized by the existing resolve gate. Expose precise persistence-failure and in-flight state through `SessionViewStore`, then render a conditional recovery button above the existing match blocker. A DEBUG launch fixture will fail its first background save and allow the second attempt so the UI test exercises the real coordinator retry path.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, XCTest UI tests, Xcode iOS Simulator.

---

## File Map

- Modify `IndustrialCityBirmingham/Session/SessionCoordinator.swift`: make the retry operation save host or guest state.
- Modify `IndustrialCityBirmingham/Session/SessionViewStore.swift`: expose failure, progress, eligibility, and retry state; add the DEBUG retry fixture.
- Modify `IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift`: render the recovery panel and button.
- Modify `IndustrialCityBirmingham/App/AppEnvironment.swift`: recognize the DEBUG retry fixture argument.
- Modify `IndustrialCityBirmingham/App/IndustrialCityBirminghamApp.swift`: construct the retry fixture.
- Modify `IndustrialCityBirminghamTests/PersistenceRecoveryTests.swift`: cover guest retry, view-store success/failure, and duplicate-tap protection.
- Modify `IndustrialCityBirminghamUITests/AccessibilityJourneyUITests.swift`: exercise the button through a fail-then-success persistence fixture.

### Task 1: Role-Aware Coordinator Retry

**Files:**
- Modify: `IndustrialCityBirminghamTests/PersistenceRecoveryTests.swift`
- Modify: `IndustrialCityBirmingham/Session/SessionCoordinator.swift:446-455`

- [ ] **Step 1: Write the failing guest retry test**

Add:

```swift
@Test func guestRetryPersistenceSavesItsCurrentPrivateProjection() async throws {
    let hostID = GameCore.PlayerID(rawValue: "host")
    let hub = LoopbackTransportHub()
    let guestPersistence = RecordingSessionArchivePersistence()
    await guestPersistence.failSaves(true)
    let host = SessionCoordinator(
        configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: hostID, reconnectToken: .init(rawValue: "host-token"), hostPlayerID: hostID
        ),
        transport: hub.makeTransport(peerID: hostID), rulesMode: .fixtureOnlyLegacy
    )
    let guest = SessionCoordinator(
        configuration: .init(
            protocolVersion: 1, rulesetVersion: "rules-v1", roomID: room,
            playerID: player, reconnectToken: .init(rawValue: "guest-token"), hostPlayerID: hostID
        ),
        transport: hub.makeTransport(peerID: player), persistence: guestPersistence,
        rulesMode: .fixtureOnlyLegacy
    )

    try await host.createRoom(); try await guest.joinRoom()
    try await host.setReady(true); try await guest.setReady(true)
    try await eventually { await host.readyPlayerIDs.count == 2 }
    try await host.startGame()
    try await eventually { await guest.persistenceError == .saveFailed }

    await guestPersistence.failSaves(false)
    try await guest.retryPersistence()

    #expect(await guest.persistenceError == nil)
    #expect(await guestPersistence.savedArchives.last?.role == .guest)
    #expect(await guestPersistence.savedArchives.last?.authoritativeVersion == .init(rawValue: 0))
}
```

- [ ] **Step 2: Run the test and verify RED**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-Task5,OS=26.5' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests/PersistenceRecoveryTests/guestRetryPersistenceSavesItsCurrentPrivateProjection
```

Expected: FAIL with `SessionCoordinator.Error.hostOnly`.

- [ ] **Step 3: Implement the minimal role-aware retry**

```swift
func retryPersistence() async throws {
    await acquireResolveGate()
    do {
        if isHost {
            try await persistCommittedState()
        } else {
            try await persistGuestState(newEvent: nil)
        }
        releaseResolveGate()
    } catch {
        releaseResolveGate()
        throw error
    }
}
```

- [ ] **Step 4: Re-run Step 2 and verify GREEN**

Expected: the guest retry test passes.

- [ ] **Step 5: Commit**

```bash
git add IndustrialCityBirmingham/Session/SessionCoordinator.swift \
  IndustrialCityBirminghamTests/PersistenceRecoveryTests.swift
git commit -m "feat: retry guest snapshot persistence"
```

### Task 2: View-Store Retry State and Safety

**Files:**
- Modify: `IndustrialCityBirminghamTests/PersistenceRecoveryTests.swift:1942-1966,2875-2889`
- Modify: `IndustrialCityBirmingham/Session/SessionViewStore.swift:90-150,545-667`

- [ ] **Step 1: Write failing view-store tests**

Add the accepted-action checkpoint case:

```swift
@MainActor
@Test func viewStoreRetryPersistsCurrentAuthorityWithoutReplayingTheAction() async throws {
    let pair = makePersistentCoordinatorPair()
    let store = SessionViewStore(
        coordinator: pair.host, role: .host, roomID: room,
        playerID: .init(rawValue: "host"), hostPlayerID: .init(rawValue: "host")
    )
    await store.connect(); try await pair.guest.joinRoom()
    await store.setReady(true); try await pair.guest.setReady(true)
    try await eventuallyMainActor { store.readyPlayerIDs.count == 2 }
    await store.startGame(); try await eventuallyMainActor { store.snapshot != nil }
    await pair.persistence.failSave(number: 2)
    store.selectCard("card-0-a")

    await store.submitPass()
    try await eventuallyMainActor { store.hasPersistenceFailure }
    #expect(store.version == .init(rawValue: 1))
    #expect(store.canRetryPersistence)

    await store.retryPersistence()
    try await eventuallyMainActor { store.syncStatus == .synchronized }

    #expect(store.version == .init(rawValue: 1))
    #expect(!store.hasPersistenceFailure)
    #expect(!store.canRetryPersistence)
    #expect(store.errorMessage == nil)
}
```

Add `viewStoreFailedRetryRemainsRetryable`: keep `failSaves(true)` during retry and assert `syncStatus == .failed`, `hasPersistenceFailure`, and `canRetryPersistence` after it returns.

Add `viewStoreIgnoresDuplicateRetryWhileSaving`: after entering failure, restore saves, delay them by 150 ms, launch two retry tasks, and assert the persistence attempt count increases by exactly one.

Extend the test persistence actor:

```swift
private var saveDelay: Duration?
var saveAttemptCount: Int { saveAttempt }

func delaySaves(by value: Duration?) { saveDelay = value }

func save(_ archive: SessionArchive) async throws {
    saveAttempt += 1
    if let saveDelay { try await Task.sleep(for: saveDelay) }
    if shouldFail || failingSaveNumbers.contains(saveAttempt) {
        throw SessionPersistenceError.saveFailed
    }
    savedArchives.append(archive)
}
```

- [ ] **Step 2: Run the tests and verify RED**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-Task5,OS=26.5' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests/PersistenceRecoveryTests/viewStoreRetryPersistsCurrentAuthorityWithoutReplayingTheAction \
  -only-testing:IndustrialCityBirminghamTests/PersistenceRecoveryTests/viewStoreFailedRetryRemainsRetryable \
  -only-testing:IndustrialCityBirminghamTests/PersistenceRecoveryTests/viewStoreIgnoresDuplicateRetryWhileSaving
```

Expected: compile failure because the view-store retry API does not exist.

- [ ] **Step 3: Add the observable retry API**

```swift
private(set) var hasPersistenceFailure = false
private(set) var isRetryingPersistence = false

var canRetryPersistence: Bool {
    hasPersistenceFailure && !isRetryingPersistence
}

func retryPersistence() async {
    guard canRetryPersistence else { return }
    isRetryingPersistence = true
    defer { isRetryingPersistence = false }
    do {
        try await coordinator.retryPersistence()
    } catch {
        hasPersistenceFailure = true
        syncStatus = .failed
        errorMessage = Self.persistenceFailureMessage
    }
}
```

Set `hasPersistenceFailure = true` in the background-save and action-submission persistence catches. At the start of `consume(_:)` assign:

```swift
hasPersistenceFailure = state.persistenceError != nil
```

Do not force synchronization on success; the coordinator publishes the authoritative post-save state.

- [ ] **Step 4: Run Tasks 1 and 2 focused tests and verify GREEN**

Expected: all retry tests pass.

- [ ] **Step 5: Commit**

```bash
git add IndustrialCityBirmingham/Session/SessionViewStore.swift \
  IndustrialCityBirminghamTests/PersistenceRecoveryTests.swift
git commit -m "feat: expose persistence retry state"
```

### Task 3: Recovery Panel and End-to-End Fixture

**Files:**
- Modify: `IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift:98-123`
- Modify: `IndustrialCityBirmingham/Session/SessionViewStore.swift` under `#if DEBUG`
- Modify: `IndustrialCityBirmingham/App/AppEnvironment.swift:3-60`
- Modify: `IndustrialCityBirmingham/App/IndustrialCityBirminghamApp.swift:83-109`
- Modify: `IndustrialCityBirminghamUITests/AccessibilityJourneyUITests.swift`

- [ ] **Step 1: Write the failing UI test**

```swift
@MainActor
func testPersistenceFailureOffersARealRetrySaveButton() {
    relaunch(arguments: ["-local-persistence-retry-ui-fixture", "-reduce-motion", "YES"])
    XCTAssertTrue(app.otherElements["real.match"].waitForExistence(timeout: 5))

    XCUIDevice.shared.press(.home)
    app.activate()

    let retry = app.buttons["real.persistence.retry"]
    XCTAssertTrue(retry.waitForExistence(timeout: 5))
    assertAccessibleControl(retry)
    XCTAssertEqual(retry.label, "重试保存")
    XCTAssertTrue(app.descendants(matching: .any)["submission.blocker"].exists)

    retry.tap()
    XCTAssertTrue(app.descendants(matching: .any)["real.persistence.retrying"]
        .waitForExistence(timeout: 2))
    let synchronized = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label CONTAINS %@", "synchronized"),
        object: app.descendants(matching: .any)["real.sync"]
    )
    XCTAssertEqual(XCTWaiter.wait(for: [synchronized], timeout: 5), .completed)
    XCTAssertFalse(app.buttons["real.persistence.retry"].exists)
}
```

- [ ] **Step 2: Run the UI test and verify RED**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-Task5,OS=26.5' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamUITests/AccessibilityJourneyUITests/testPersistenceFailureOffersARealRetrySaveButton
```

Expected: FAIL because the launch fixture and retry button do not exist.

- [ ] **Step 3: Add the DEBUG fail-then-success fixture**

Add:

```swift
private actor PersistenceRetryUIFixtureStore: SessionArchivePersisting {
    private var attemptCount = 0

    func save(_ archive: SessionArchive) async throws {
        attemptCount += 1
        if attemptCount == 1 { throw SessionPersistenceError.saveFailed }
        try await Task.sleep(for: .milliseconds(300))
    }
}
```

Add `SessionViewStore.localPersistenceRetryUIFixture()` by sharing the existing loopback local-UI construction and injecting this actor into the host coordinator.

Add `.localPersistenceRetryUIFixture` to `AppEnvironment.Mode`, select it for `-local-persistence-retry-ui-fixture`, and return the new store from `IndustrialCityBirminghamApp.makeRealSession(for:)`.

- [ ] **Step 4: Render the actionable panel**

Replace the text-only banner with a recovery-panel helper that retains `real.recovery`. Inside it render:

```swift
if store.hasPersistenceFailure {
    Button {
        Task { await store.retryPersistence() }
    } label: {
        HStack(spacing: 8) {
            if store.isRetryingPersistence {
                ProgressView().tint(BrassColor.paper.color)
            }
            Image(systemName: store.isRetryingPersistence
                ? "externaldrive.badge.timemachine"
                : "arrow.clockwise")
            Text(store.isRetryingPersistence ? "正在保存…" : "重试保存")
        }
        .frame(minHeight: 44)
    }
    .buttonStyle(BrassPrimaryButtonStyle())
    .disabled(!store.canRetryPersistence)
    .accessibilityIdentifier(
        store.isRetryingPersistence
            ? "real.persistence.retrying"
            : "real.persistence.retry"
    )
}
```

Keep the panel above the hand inset and add `.accessibilityElement(children: .contain)` so the message and button remain independently accessible.

- [ ] **Step 5: Re-run Step 2 and verify GREEN**

Expected: the fixture fails after backgrounding, the button is hittable, and tapping it returns to synchronized state.

- [ ] **Step 6: Commit**

```bash
git add IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift \
  IndustrialCityBirmingham/Session/SessionViewStore.swift \
  IndustrialCityBirmingham/App/AppEnvironment.swift \
  IndustrialCityBirmingham/App/IndustrialCityBirminghamApp.swift \
  IndustrialCityBirminghamUITests/AccessibilityJourneyUITests.swift
git commit -m "feat: add retry save recovery control"
```

### Task 4: Regression Verification

- [ ] **Step 1: Run all persistence tests serially**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-Task5,OS=26.5' \
  -parallel-testing-enabled NO \
  -only-testing:IndustrialCityBirminghamTests/PersistenceRecoveryTests
```

Expected: zero failures.

- [ ] **Step 2: Run the full unit suite serially**

```bash
xcodebuild test -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'platform=iOS Simulator,name=IndustrialCity-Task5,OS=26.5' \
  -parallel-testing-enabled NO \
  -skip-testing:IndustrialCityBirminghamUITests
```

Expected: zero failures.

- [ ] **Step 3: Build the app**

```bash
xcodebuild build -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
  -destination 'generic/platform=iOS Simulator'
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the retry UI journey on iPhone and iPad**

Run the Task 3 UI test once on `IndustrialCity-iPhone` and once on `IndustrialCity-iPad` with serial testing. Expected: both pass; the button remains above the phone hand dock and clear of tablet rails.

- [ ] **Step 5: Check repository hygiene**

```bash
git diff --check
git status --short --branch
```

Expected: no whitespace errors and only intentional committed changes.

