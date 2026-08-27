import XCTest

final class AccessibilityJourneyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = MainActor.assumeIsolated {
            XCUIDevice.shared.orientation = .landscapeLeft
            return Self.launch(arguments: ["-ui-testing"])
        }
    }

    @MainActor
    func testCreateJoinReadyStartJourney() {
        app.buttons["home.online"].tap()
        assertAccessibleControl(app.buttons["online.create"])
        XCTAssertTrue(app.buttons["online.join"].exists)
        XCTAssertFalse(app.buttons["online.join"].label.isEmpty)
        XCTAssertFalse(app.buttons["online.join"].isEnabled)
        assertUniqueIdentifier("online.create")
        assertUniqueIdentifier("online.join")

        app.buttons["online.create"].tap()
        let players = app.descendants(matching: .any).matching(identifier: "lobby.player")
        XCTAssertTrue(app.buttons["lobby.start"].waitForExistence(timeout: 3))
        XCTAssertEqual(players.count, 4)
        for index in 0..<players.count {
            XCTAssertTrue(players.element(boundBy: index).label.contains("已准备"))
            XCTAssertFalse(players.element(boundBy: index).label.isEmpty)
        }
        app.scrollViews.firstMatch.swipeUp()
        app.scrollViews.firstMatch.swipeUp()
        assertAccessibleControl(app.buttons["lobby.start"])
        assertUniqueIdentifier("lobby.start")

        app.terminate()
        app = Self.launch(arguments: ["-ui-testing"])
        app.buttons["home.online"].tap()
        let roomCode = app.textFields["online.join.code"]
        XCTAssertTrue(roomCode.waitForExistence(timeout: 2))
        roomCode.tap()
        roomCode.typeText("ABC123")
        let join = app.buttons["online.join"]
        XCTAssertTrue(join.isEnabled)
        XCTAssertFalse(join.label.isEmpty)
        XCTAssertGreaterThanOrEqual(join.frame.width, 44)
        XCTAssertGreaterThanOrEqual(join.frame.height, 44)
        join.tap()
        XCTAssertTrue(app.buttons["lobby.start"].waitForExistence(timeout: 3))

        relaunch(arguments: ["-local-role", "host", "-local-room", "A11YREADY", "-local-port", "0"])
        let ready = app.buttons["real.ready"]
        assertAccessibleControl(ready)
        assertUniqueIdentifier("real.ready")
        XCTAssertEqual(ready.label, "准备")
        ready.tap()
        let readyStateChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "取消准备"),
            object: ready
        )
        XCTAssertEqual(XCTWaiter.wait(for: [readyStateChanged], timeout: 3), .completed)
    }

    @MainActor
    func testTurnResourcesHandCardActionTargetAndConfirmationJourney() {
        enterPreviewMatch()

        for identifier in ["match.header", "market.coal", "market.iron"] {
            let element = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(element.waitForExistence(timeout: 3), "Missing \(identifier)")
            XCTAssertFalse(element.label.isEmpty, "Unlabeled \(identifier)")
            assertUniqueIdentifier(identifier)
        }
        XCTAssertTrue(app.descendants(matching: .any)["match.hand"].exists)
        assertUniqueIdentifier("match.hand")

        let card = app.buttons["hand.card.card-birmingham"]
        assertAccessibleControl(card)
        card.tap()
        assertAccessibleControl(app.buttons["match.actionButton"])
        app.buttons["match.actionButton"].tap()
        assertAccessibleControl(app.buttons["action.build"])
        app.buttons["action.build"].tap()

        let target = app.buttons["flow.target.birmingham"]
        assertAccessibleControl(target)
        target.tap()
        let confirmation = app.descendants(matching: .any)["action.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        assertAccessibleControl(app.buttons["action.confirm"])
        assertAccessibleControl(app.buttons["action.cancel"])
        assertUniqueIdentifier("action.confirmation")
    }

    @MainActor
    func testRejectionRecoveryPausedAndSyncingJourney() {
        relaunch(arguments: ["-ui-testing", "-fixture", "rejectedAction"])
        for identifier in ["event.rejected", "event.rejection.reason", "event.rejection.recovery"] {
            let element = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(element.waitForExistence(timeout: 3), "Missing \(identifier)")
            XCTAssertFalse(element.label.isEmpty, "Unlabeled \(identifier)")
            assertUniqueIdentifier(identifier)
        }

        relaunch(arguments: ["-ui-testing", "-fixture", "versionMismatch"])
        let recovery = app.descendants(matching: .any)["online.state"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 3))
        XCTAssertTrue(recovery.label.contains("规则版本不一致"))
        let recoverySelector = app.descendants(matching: .any)["online.state.selector"]
        XCTAssertTrue(recoverySelector.exists)
        XCTAssertTrue(recoverySelector.isEnabled)
        XCTAssertGreaterThanOrEqual(recoverySelector.frame.height, 44)
        let recoveryOption = app.buttons["待机"]
        XCTAssertTrue(recoveryOption.exists)
        XCTAssertFalse(recoveryOption.label.isEmpty)
        XCTAssertTrue(recoveryOption.isHittable)

        relaunch(arguments: ["-ui-testing", "-fixture", "disconnected"])
        let paused = app.descendants(matching: .any)["match.playerRail"]
        XCTAssertTrue(paused.waitForExistence(timeout: 3))
        XCTAssertTrue(paused.label.contains("离线"))
        XCTAssertFalse(paused.label.isEmpty)

        relaunch(arguments: ["-local-recovery-ui-fixture", "-reduce-motion", "YES"])
        XCTAssertTrue(app.otherElements["real.match"].waitForExistence(timeout: 5))
        let syncing = app.descendants(matching: .any)["real.sync"]
        XCTAssertTrue(syncing.waitForExistence(timeout: 3))
        let pass = app.buttons["action.pass"]
        let connecting = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "connecting"),
            object: syncing
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [connecting], timeout: 3),
            .completed,
            "Expected connecting, observed \(syncing.label)"
        )
        XCTAssertFalse(pass.exists)
        let advanceRecovery = app.buttons["real.recovery.advance"]
        assertAccessibleControl(advanceRecovery)
        advanceRecovery.tap()

        let recovering = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "recovering"),
            object: syncing
        )
        XCTAssertEqual(XCTWaiter.wait(for: [recovering], timeout: 4), .completed)
        let recoveryHint = app.descendants(matching: .any)["real.recovery"]
        XCTAssertTrue(recoveryHint.waitForExistence(timeout: 2))
        XCTAssertFalse(recoveryHint.label.isEmpty)
        XCTAssertTrue(recoveryHint.label.contains("暂停"))
        XCTAssertFalse(pass.exists)
        advanceRecovery.tap()

        let synchronized = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "synchronized"),
            object: syncing
        )
        XCTAssertEqual(XCTWaiter.wait(for: [synchronized], timeout: 4), .completed)
        let selectedCard = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'hand.card.'"
        )).firstMatch
        XCTAssertTrue(selectedCard.waitForExistence(timeout: 2))
        selectedCard.tap()
        XCTAssertTrue(pass.waitForExistence(timeout: 2))
        XCTAssertTrue(pass.isEnabled)
        XCTAssertFalse(syncing.label.isEmpty)
        assertUniqueIdentifier("real.sync")
    }

    @MainActor
    func testSegmentedPickerHitTargetsAreAtLeast44Points() {
        continueAfterFailure = true

        relaunch(arguments: ["-ui-testing", "-fixture", "versionMismatch"])
        assertMinimumHitTarget("online.state.selector")

        relaunch(arguments: ["-ui-testing", "-fixture", "wirelessOff"])
        assertMinimumHitTarget("nearby.preflight.selector")

        relaunch(arguments: ["-ui-testing"])
        app.buttons["home.online"].tap()
        app.buttons["online.create"].tap()
        XCTAssertTrue(app.buttons["lobby.start"].waitForExistence(timeout: 3))
        assertMinimumHitTarget("lobby.playerCount.selector")
    }

    @MainActor
    private func enterPreviewMatch() {
        app.buttons["home.online"].tap()
        app.buttons["online.create"].tap()
        let start = app.buttons["lobby.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        app.scrollViews.firstMatch.swipeUp()
        app.scrollViews.firstMatch.swipeUp()
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["match.shell"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func relaunch(arguments: [String]) {
        app.terminate()
        app = Self.launch(arguments: arguments)
    }

    @MainActor
    private static func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func assertAccessibleControl(
        _ control: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(control.waitForExistence(timeout: 3), "Missing control \(control)", file: file, line: line)
        XCTAssertFalse(control.label.isEmpty, "Unlabeled control \(control)", file: file, line: line)
        XCTAssertTrue(
            control.isHittable,
            "Control is not hittable: \(control); enabled=\(control.isEnabled); frame=\(control.frame)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            control.frame.width,
            44,
            "Control is too narrow: \(control.frame)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            control.frame.height,
            44,
            "Control is too short: \(control.frame)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertUniqueIdentifier(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: identifier).count,
            1,
            "Duplicate or missing accessibility identifier \(identifier)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertMinimumHitTarget(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 3), "Missing \(identifier)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, file: file, line: line)
    }
}
