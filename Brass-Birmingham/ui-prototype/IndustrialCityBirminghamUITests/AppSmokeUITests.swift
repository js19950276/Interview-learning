import XCTest

final class AppSmokeUITests: XCTestCase {
    private var activeApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func record(_ issue: XCTIssue) {
        if let activeApp {
            let screenshot = XCTAttachment(
                screenshot: MainActor.assumeIsolated { activeApp.screenshot() }
            )
            screenshot.name = "failure.png"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        super.record(issue)
    }

    @MainActor
    func testLaunchShowsHomeTitle() throws {
        let app = launchApp()
        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["home.title"].label, "工业城市伯明翰")
    }

    @MainActor
    func testOnlineRoomCreatesFourPlayerLobby() throws {
        let app = launchApp()

        app.buttons["home.online"].tap()

        XCTAssertTrue(app.buttons["online.create"].waitForExistence(timeout: 2))
        let roomCode = app.textFields["online.join.code"]
        let joinButton = app.buttons["online.join"]
        XCTAssertTrue(roomCode.exists)
        XCTAssertTrue(joinButton.exists)
        XCTAssertTrue(app.descendants(matching: .any)["online.state"].exists)
        XCTAssertFalse(joinButton.isEnabled)

        let scrollView = app.scrollViews.firstMatch
        let safeFrame = app.windows.firstMatch.frame.insetBy(dx: 8, dy: 8)
        var scrollAttempts = 0
        while !safeFrame.contains(roomCode.frame), scrollAttempts < 3 {
            scrollView.swipeUp()
            scrollAttempts += 1
        }
        XCTAssertTrue(safeFrame.contains(roomCode.frame), "Room code field must be fully visible before typing")
        roomCode.tap()
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "hasKeyboardFocus == true"),
                        object: roomCode
                    )
                ],
                timeout: 2
            ),
            .completed
        )
        roomCode.typeText("a")
        XCTAssertFalse(joinButton.isEnabled)
        roomCode.typeText("bc123")
        XCTAssertEqual(roomCode.value as? String, "ABC123")
        XCTAssertTrue(joinButton.isEnabled)

        joinButton.tap()

        XCTAssertTrue(app.buttons["lobby.start"].waitForExistence(timeout: 2))
        let players = app.descendants(matching: .any).matching(identifier: "lobby.player")
        XCTAssertEqual(players.count, 4)
        XCTAssertTrue(players.element(boundBy: 0).label.contains("琥珀色"))
        XCTAssertTrue(players.element(boundBy: 0).label.contains("菱形标记"))
        XCTAssertTrue(players.element(boundBy: 0).label.contains("£0"))
    }

    @MainActor
    func testNearbyRoomCreatesFourPlayerLobby() throws {
        let app = launchApp()

        app.buttons["home.nearby"].tap()

        XCTAssertTrue(app.buttons["nearby.create"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["nearby.search"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["nearby.preflight"].exists)

        app.buttons["nearby.create"].tap()

        XCTAssertTrue(app.buttons["lobby.start"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "lobby.player").count, 4)
    }

    @MainActor
    func testDebugNearbyRoomNeedsNoLaunchSwitchToEnableRealCreateRoomControl() throws {
        let app = launchProductionApp(arguments: [])

        app.buttons["home.nearby"].tap()

        let createButton = app.buttons["nearby.create"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 3))
        XCTAssertTrue(createButton.isEnabled)
        XCTAssertFalse(app.staticTexts["游戏数据不可用"].exists)

        createButton.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["real.room"].waitForExistence(timeout: 8),
            "Creating a Debug nearby room without launch switches must open the real lobby"
        )
    }

    @MainActor
    func testMatchShellFillsLandscapeWindowAndKeepsMapInteractive() throws {
        let app = launchApp()

        app.buttons["home.online"].tap()
        XCTAssertTrue(app.buttons["online.create"].waitForExistence(timeout: 2))
        app.buttons["online.create"].tap()

        let startButton = app.buttons["lobby.start"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 2))
        app.scrollViews.firstMatch.swipeUp()
        app.scrollViews.firstMatch.swipeUp()
        startButton.tap()

        let identifiers = [
            "match.shell",
            "match.header",
            "match.map",
            "match.playerRail",
            "match.industryRail",
            "match.hand",
            "match.actionButton"
        ]
        for identifier in identifiers {
            XCTAssertTrue(
                app.descendants(matching: .any)[identifier].waitForExistence(timeout: 3),
                "Missing \(identifier)"
            )
        }

        let windowFrame = app.windows.firstMatch.frame
        let shellFrame = app.descendants(matching: .any)["match.shell"].frame
        let map = app.descendants(matching: .any)["match.map"]
        let mapFrame = map.frame
        let visibleShellFrame = shellFrame.intersection(windowFrame)
        let relaxedWindowFrame = windowFrame.insetBy(dx: -24, dy: -24)

        XCTAssertGreaterThan(windowFrame.width, windowFrame.height)
        XCTAssertGreaterThan(shellFrame.width, shellFrame.height)
        XCTAssertGreaterThanOrEqual(
            visibleShellFrame.width,
            windowFrame.width * 0.9,
            "window=\(windowFrame), shell=\(shellFrame), visibleShell=\(visibleShellFrame), map=\(mapFrame)"
        )
        XCTAssertGreaterThanOrEqual(
            visibleShellFrame.height,
            windowFrame.height * 0.9,
            "window=\(windowFrame), shell=\(shellFrame), visibleShell=\(visibleShellFrame), map=\(mapFrame)"
        )
        XCTAssertTrue(
            relaxedWindowFrame.contains(mapFrame),
            "window=\(windowFrame), shell=\(shellFrame), map=\(mapFrame)"
        )
        XCTAssertGreaterThanOrEqual(shellFrame.width, windowFrame.width * 0.9)
        XCTAssertGreaterThanOrEqual(shellFrame.height, windowFrame.height * 0.9)
        XCTAssertGreaterThanOrEqual(mapFrame.width, windowFrame.width * 0.9)
        XCTAssertGreaterThanOrEqual(mapFrame.height, windowFrame.height * 0.9)

        map.swipeLeft()
        map.pinch(withScale: 1.5, velocity: 1)
        XCTAssertTrue(map.exists)
    }

    @MainActor
    func testMapPinchChangesReportedZoomInAndOut() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchApp(arguments: ["-fixture", "players4"])
        XCUIDevice.shared.orientation = .landscapeLeft

        let map = app.descendants(matching: .any)["match.map"]
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        XCTAssertEqual(map.value as? String, "缩放 0.75 倍")

        map.pinch(withScale: 1.6, velocity: 1)
        let zoomedIn = try XCTUnwrap(map.value as? String)
        XCTAssertNotEqual(zoomedIn, "缩放 0.75 倍")

        map.pinch(withScale: 0.2, velocity: -1)
        XCTAssertEqual(map.value as? String, "缩放 0.75 倍")
    }

    @MainActor
    func testPhoneFixtureKeepsMatchShellAndHandInsideWindowBounds() throws {
        XCUIDevice.shared.orientation = .landscapeRight
        let app = launchApp(arguments: ["-fixture", "players4"])
        XCUIDevice.shared.orientation = .landscapeRight

        let window = app.windows.firstMatch
        guard window.frame.width < 1_000 else {
            throw XCTSkip("iPhone-only safe-area behavior")
        }

        let shell = app.descendants(matching: .any)["match.shell"]
        let hand = app.descendants(matching: .any)["match.hand"]
        let playerRail = app.buttons["match.playerRail"]
        let industryRail = app.buttons["match.industryRail"]
        XCTAssertTrue(shell.waitForExistence(timeout: 5))
        XCTAssertTrue(hand.waitForExistence(timeout: 2))
        XCTAssertTrue(playerRail.exists)
        XCTAssertTrue(industryRail.exists)

        XCTAssertLessThanOrEqual(
            shell.frame.maxY,
            window.frame.maxY + 1,
            "Match shell must stay inside the iPhone window; window=\(window.frame), shell=\(shell.frame), hand=\(hand.frame)"
        )
        XCTAssertLessThanOrEqual(
            hand.frame.maxY,
            window.frame.maxY + 1,
            "Hand dock must stay inside the iPhone window; window=\(window.frame), hand=\(hand.frame)"
        )
        XCTAssertLessThanOrEqual(
            playerRail.frame.maxY,
            hand.frame.minY + 1,
            "Player rail must end above the hand; rail=\(playerRail.frame), hand=\(hand.frame)"
        )
        XCTAssertLessThanOrEqual(
            industryRail.frame.maxY,
            hand.frame.minY + 1,
            "Industry rail must end above the hand; rail=\(industryRail.frame), hand=\(hand.frame)"
        )

        let evidence = XCTAttachment(
            string: "window=\(window.frame), shell=\(shell.frame), hand=\(hand.frame), playerRail=\(playerRail.frame), industryRail=\(industryRail.frame)"
        )
        evidence.name = "iphone-match-safe-area-frames"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor
    func testPhoneRealFixtureKeepsMatchChromeInsideWindowBounds() throws {
        XCUIDevice.shared.orientation = .landscapeRight
        let app = launchProductionApp(arguments: ["-local-ui-fixture", "-reduce-motion", "YES"])
        XCUIDevice.shared.orientation = .landscapeRight

        let window = app.windows.firstMatch
        guard window.frame.width < 1_000 else {
            throw XCTSkip("iPhone-only safe-area behavior")
        }

        let shell = app.descendants(matching: .any)["real.match"]
        let hand = app.descendants(matching: .any)["real.hand"]
        let playerRail = app.buttons["real.playerRail.toggle"]
        let industryRail = app.buttons["real.industryRail.toggle"]
        XCTAssertTrue(shell.waitForExistence(timeout: 8))
        XCTAssertTrue(hand.waitForExistence(timeout: 2))
        XCTAssertTrue(playerRail.exists)
        XCTAssertTrue(industryRail.exists)

        XCTAssertLessThanOrEqual(shell.frame.maxY, window.frame.maxY + 1)
        XCTAssertLessThanOrEqual(hand.frame.maxY, window.frame.maxY + 1)
        XCTAssertLessThanOrEqual(playerRail.frame.maxY, hand.frame.minY + 1)
        XCTAssertLessThanOrEqual(industryRail.frame.maxY, hand.frame.minY + 1)

        let evidence = XCTAttachment(
            string: "window=\(window.frame), shell=\(shell.frame), hand=\(hand.frame), playerRail=\(playerRail.frame), industryRail=\(industryRail.frame)"
        )
        evidence.name = "iphone-real-match-safe-area-frames"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor
    func testPlayerCountFixturesLaunchNamedMatchStates() {
        for count in 2...4 {
            let fixture = "players\(count)"
            let app = launchApp(arguments: ["-fixture", fixture])

            let playerRail = app.descendants(matching: .any)["match.playerRail"]
            XCTAssertTrue(playerRail.waitForExistence(timeout: 4))
            XCTAssertEqual(playerRail.value as? String, "\(count) 位玩家")
            XCTAssertTrue(playerRail.label.contains("Owen"))
            if app.windows.firstMatch.frame.width >= 1_000 {
                let players = app.descendants(matching: .any).matching(
                    NSPredicate(format: "identifier BEGINSWITH 'match.player.'")
                )
                XCTAssertEqual(players.count, count, "Incorrect real player count for \(fixture)")
            }
            assertAccessibleControl(app.buttons["match.actionButton"])

            app.terminate()
        }
    }

    @MainActor
    func testConnectionErrorFixturesLaunchNamedRecoveryScreens() {
        let fixtures = [
            (name: "wirelessOff", panelIdentifier: "nearby.preflight", control: "nearby.create", selector: "nearby.preflight.selector", recovery: "搜索", text: "无线连接已关闭"),
            (name: "versionMismatch", panelIdentifier: "online.state", control: "online.create", selector: "online.state.selector", recovery: "待机", text: "规则版本不一致")
        ]

        for fixture in fixtures {
            let app = launchApp(arguments: ["-fixture", fixture.name])
            let statePanel = app.descendants(matching: .any)[fixture.panelIdentifier]
            let blockedControl = app.buttons[fixture.control]
            XCTAssertTrue(statePanel.waitForExistence(timeout: 3))
            XCTAssertTrue(statePanel.label.contains(fixture.text))
            XCTAssertTrue(blockedControl.exists)
            XCTAssertFalse(blockedControl.isEnabled)
            XCTAssertFalse(blockedControl.label.isEmpty)
            XCTAssertGreaterThanOrEqual(blockedControl.frame.width, 44)
            XCTAssertGreaterThanOrEqual(blockedControl.frame.height, 44)
            XCTAssertTrue(app.descendants(matching: .any)[fixture.selector].isEnabled)
            let recoveryOption = app.buttons[fixture.recovery]
            XCTAssertTrue(recoveryOption.exists)
            recoveryOption.tap()
            XCTAssertTrue(blockedControl.isEnabled)
            app.terminate()
        }
    }

    @MainActor
    func testGalleryCoversInteractionAccessibilityStateMatrix() {
        let app = launchApp()
        app.buttons["home.gallery"].tap()

        let components = ["button", "panel", "player", "resource"]
        let states = ["normal", "pressed", "disabled", "selected", "illegal", "waiting", "disconnected", "reduced-motion"]
        XCTAssertTrue(app.descendants(matching: .any)["gallery.button.normal"].waitForExistence(timeout: 2))

        for component in components {
            for state in states {
                let identifier = "gallery.\(component).\(state)"
                let sample = app.descendants(matching: .any)[identifier]
                XCTAssertTrue(sample.exists, "Missing gallery component state \(identifier)")
                XCTAssertFalse(sample.label.isEmpty, "Missing accessibility label for \(identifier)")
                XCTAssertGreaterThanOrEqual(sample.frame.width, 44, "Narrow gallery component \(identifier)")
                XCTAssertGreaterThanOrEqual(sample.frame.height, 44, "Short gallery component \(identifier)")
            }
        }
        for state in states {
            assertAccessibleControl(app.buttons["gallery.button.\(state)"])
        }
        XCTAssertTrue(app.staticTexts["gallery.player.longChinese"].label.contains("中文"))
        XCTAssertTrue(app.staticTexts["gallery.player.longEnglish"].label.contains("English"))
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'gallery.colorAssist.'")).count, 4)
    }

    @MainActor
    private func launchApp(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"] + arguments
        app.launch()
        activeApp = app
        return app
    }

    @MainActor
    private func launchProductionApp(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        activeApp = app
        return app
    }

    @MainActor
    private func assertAccessibleControl(
        _ control: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(control.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertFalse(control.label.isEmpty, file: file, line: line)
        XCTAssertGreaterThanOrEqual(control.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(control.frame.height, 44, file: file, line: line)
    }
}
