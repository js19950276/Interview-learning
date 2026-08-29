import XCTest

final class SnapshotCaptureUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCapturePhoneSnapshots() throws {
        try requireRunnerIdiom(.phone)
        captureHome(named: "home-phone")
        captureOnlineError(named: "online-error-phone")
        captureNearbyPermission(named: "nearby-permission-phone")
        captureLobby(named: "lobby-4-phone")
        captureMatch(fixture: "players2", named: "match-2-phone")
        captureMatch(fixture: "players3", named: "match-3-phone")
        captureMatch(fixture: "players4", named: "match-4-phone")
        captureBuild(named: "match-build-phone")
        captureSell(named: "match-sell-phone")
        captureDisconnected(named: "match-disconnected-phone")
    }

    @MainActor
    func testCaptureIPadSnapshots() throws {
        try requireRunnerIdiom(.pad)
        captureHome(named: "home-ipad", orientation: .landscapeLeft)
        captureMatch(fixture: "players4", named: "match-4-ipad")
    }

    @MainActor
    private func captureHome(named name: String, orientation: UIDeviceOrientation = .portrait) {
        XCUIDevice.shared.orientation = orientation
        launch()
        XCUIDevice.shared.orientation = orientation
        assertWindowOrientation(orientation)
        captureStableScreen(named: name)
    }

    @MainActor
    private func captureOnlineError(named name: String) {
        XCUIDevice.shared.orientation = .portrait
        launch()
        app.buttons["home.online"].tap()
        let selector = app.segmentedControls["online.state.selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 3))
        selector.buttons["无房间"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["online.state"].label.contains("没有找到"))
        captureStableScreen(named: name)
    }

    @MainActor
    private func captureNearbyPermission(named name: String) {
        XCUIDevice.shared.orientation = .portrait
        launch()
        app.buttons["home.nearby"].tap()
        let selector = app.segmentedControls["nearby.preflight.selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 3))
        selector.buttons["权限"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["nearby.preflight"].label.contains("权限未授权"))
        captureStableScreen(named: name)
    }

    @MainActor
    private func captureLobby(named name: String) {
        XCUIDevice.shared.orientation = .portrait
        launch()
        app.buttons["home.online"].tap()
        let create = app.buttons["online.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        XCTAssertTrue(app.buttons["lobby.start"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "lobby.player").count, 4)
        captureStableScreen(named: name)
    }

    @MainActor
    private func captureMatch(fixture: String, named name: String) {
        launchLandscapeMatch(arguments: ["-fixture", fixture])
        XCTAssertTrue(app.descendants(matching: .any)["match.shell"].waitForExistence(timeout: 5))
        captureStableScreen(named: name)
    }

    @MainActor
    private func captureDisconnected(named name: String) {
        launchLandscapeMatch(arguments: ["-fixture", "disconnected"])

        let disconnectedPlayer = app.descendants(matching: .any)["match.player.player-crimson"]
        XCTAssertTrue(disconnectedPlayer.waitForExistence(timeout: 5))
        XCTAssertTrue(disconnectedPlayer.label.contains("离线"))

        app.buttons["match.playerRail"].tap()
        let drawer = app.descendants(matching: .any)["overlay.playerRail"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 2))
        let visibleDisconnectedPlayer = app.descendants(matching: .any)["drawer.player.player-crimson"]
        XCTAssertTrue(visibleDisconnectedPlayer.waitForExistence(timeout: 2))
        XCTAssertTrue(visibleDisconnectedPlayer.label.contains("离线"))
        captureStableScreen(named: name)
    }

    @MainActor
    private func captureBuild(named name: String) {
        launchLandscapeMatch(arguments: ["-fixture", "players4"])
        openAction("build")
        let target = app.buttons["flow.target.birmingham"]
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        target.tap()
        XCTAssertTrue(app.buttons["action.confirm"].isEnabled)
        captureStableScreen(named: name)
    }

    @MainActor
    private func captureSell(named name: String) {
        launchLandscapeMatch(arguments: ["-fixture", "players4"])
        openAction("sell")
        let industry = app.buttons["industry.select.industry-cotton"]
        XCTAssertTrue(industry.waitForExistence(timeout: 3))
        industry.tap()
        let option = app.buttons["sell.option.sell-cotton-oxford"]
        XCTAssertTrue(option.waitForExistence(timeout: 2))
        option.tap()
        XCTAssertTrue(app.buttons["action.confirm"].isEnabled)
        captureStableScreen(named: name)
    }

    @MainActor
    private func openAction(_ action: String) {
        XCTAssertTrue(app.buttons["hand.card.card-birmingham"].waitForExistence(timeout: 5))
        app.buttons["hand.card.card-birmingham"].tap()
        app.buttons["match.actionButton"].tap()
        let actionButton = app.buttons["action.\(action)"]
        XCTAssertTrue(actionButton.waitForExistence(timeout: 2))
        actionButton.tap()
    }

    @MainActor
    private func launch(arguments: [String] = []) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-snapshot-testing",
            "-AppleInterfaceStyle", "Dark",
            "-reduce-motion", "YES",
            "-color-assist", "YES"
        ] + arguments
        app.launch()
    }

    @MainActor
    private func launchLandscapeMatch(arguments: [String]) {
        XCUIDevice.shared.orientation = .landscapeLeft
        launch(arguments: arguments)
        XCUIDevice.shared.orientation = .landscapeLeft
        assertWindowOrientation(.landscapeLeft)
    }

    @MainActor
    private func requireRunnerIdiom(_ expected: UIUserInterfaceIdiom) throws {
        let actual = UIDevice.current.userInterfaceIdiom
        guard actual == expected else {
            throw XCTSkip("Snapshot method requires \(expected == .pad ? "iPad" : "iPhone") runner; actual idiom is \(actual.rawValue)")
        }
    }

    @MainActor
    private func captureStableScreen(named name: String) {
        XCTAssertTrue(
            app.descendants(matching: .any)["snapshot.ready"].waitForExistence(timeout: 4),
            "Stable screen never exposed snapshot.ready for \(name)"
        )
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func assertWindowOrientation(_ orientation: UIDeviceOrientation) {
        let window = app.windows.firstMatch
        let predicate = NSPredicate { _, _ in
            let frame = window.frame
            return orientation.isLandscape ? frame.width > frame.height : frame.height > frame.width
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 4),
            .completed,
            "Window did not reach \(orientation.isLandscape ? "landscape" : "portrait") orientation"
        )
    }
}
