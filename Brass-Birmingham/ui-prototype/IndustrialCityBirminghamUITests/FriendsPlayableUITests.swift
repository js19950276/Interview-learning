import XCTest

final class FriendsPlayableUITests: XCTestCase {
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
    func testRealFixtureLandscapeVisualEvidence() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-local-ui-fixture", "-reduce-motion", "YES"]
        app.launch()
        XCTAssertTrue(app.otherElements["real.match"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["运河时代"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["map.routeLegend"].waitForExistence(timeout: 2))
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "real-fixture-ipad-landscape"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testRailEraLandscapeVisualEvidence() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-local-ui-fixture", "-rail-fixture", "-reduce-motion", "YES"]
        app.launch()
        XCTAssertTrue(app.otherElements["real.match"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["铁路时代"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["map.routeLegend"].waitForExistence(timeout: 2))
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "real-fixture-rail-era-landscape"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLocalUIFixtureShowsRecipientHandAndSettlesPass() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-local-ui-fixture", "-reduce-motion", "YES"]
        app.launch()

        XCTAssertTrue(app.otherElements["real.match"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["real.room"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["real.turn.status"].exists)
        let sync = app.descendants(matching: .any)["real.sync"]
        XCTAssertTrue(sync.exists)
        XCTAssertTrue(sync.label.contains("synchronized"))
        XCTAssertTrue(app.descendants(matching: .any)["market.coal"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["market.iron"].exists)
        XCTAssertFalse(app.staticTexts["real.previewNotice"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["match.map"].exists)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'hand.card.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        let cardIdentifier = card.identifier
        let pass = app.buttons["action.pass"]
        XCTAssertFalse(pass.exists, "Action panel stays closed until a legal card is selected")
        card.tap()
        XCTAssertTrue(pass.waitForExistence(timeout: 2))
        XCTAssertTrue(pass.isEnabled)
        pass.tap()
        let confirm = app.buttons["action.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.tap()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'v1'")).firstMatch
            .waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons[cardIdentifier].waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testRealBuildFlowSubmitsTypedIntentAndSettlesAuthoritativeVersion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-local-ui-fixture", "-reduce-motion", "YES"]
        app.launch()
        XCTAssertTrue(app.otherElements["real.match"].waitForExistence(timeout: 5))

        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'hand.card.'"))
        var submittedCardID: String?
        for index in 0..<cards.count {
            let card = cards.element(boundBy: index)
            let cardID = card.identifier
            card.tap()
            let build = app.buttons["action.build"]
            guard build.isEnabled else { continue }
            build.tap()
            let breweryTile = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH 'legal.choice.tile:' AND label == '啤酒厂'"
            )).firstMatch
            guard breweryTile.waitForExistence(timeout: 1) else { continue }
            breweryTile.tap()
            let target = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH 'legal.choice.build:'"
            )).firstMatch
            guard target.waitForExistence(timeout: 1) else { continue }
            target.tap()
            submittedCardID = cardID
            break
        }
        XCTAssertNotNil(submittedCardID, "Fixture hand must expose at least one legal brewery build")

        let confirm = app.buttons["action.confirm"]
        for _ in 0..<4 where !confirm.exists {
            let source = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH 'legal.choice.source:'"
            )).firstMatch
            XCTAssertTrue(source.waitForExistence(timeout: 2))
            source.tap()
        }
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'v1'")).firstMatch
            .waitForExistence(timeout: 3))
        if let submittedCardID {
            XCTAssertTrue(app.buttons[submittedCardID].waitForNonExistence(timeout: 2))
        }
        XCTAssertTrue(app.buttons["action.confirm"].waitForNonExistence(timeout: 2))
        XCTAssertFalse(app.buttons["action.build"].exists, "Accepted version clears the local action reducer")
    }

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

        let current: XCUIElement
        if app.buttons["real.playerRail.toggle"].exists {
            current = app.buttons["real.playerRail.toggle"]
        } else {
            current = app.descendants(matching: .any)["match.player.host"]
        }
        XCTAssertTrue(current.waitForExistence(timeout: 2))
        XCTAssertTrue(current.label.contains("当前玩家"))
        XCTAssertTrue(current.label.contains("你"))
        XCTAssertTrue(
            String(describing: current.value ?? "").contains("行动"),
            "Current player rail element should expose action status in its value; value=\(String(describing: current.value))"
        )
    }

    @MainActor
    func testPhoneAuthoritativeRailsToggleAndStayMutuallyExclusive() throws {
        let app = launchLocalFixture()
        guard app.windows.firstMatch.frame.width < 1_000 else {
            throw XCTSkip("iPhone-only rail behavior")
        }

        let playerToggle = app.buttons["real.playerRail.toggle"]
        let industryToggle = app.buttons["real.industryRail.toggle"]
        XCTAssertTrue(playerToggle.waitForExistence(timeout: 2))
        XCTAssertTrue(industryToggle.exists)
        XCTAssertTrue(String(describing: playerToggle.value ?? "").contains("已收起"))
        XCTAssertTrue(String(describing: playerToggle.value ?? "").contains("行动"))

        playerToggle.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["overlay.playerRail"]
                .waitForExistence(timeout: 1)
        )
        XCTAssertTrue(String(describing: playerToggle.value ?? "").contains("已展开"))

        industryToggle.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["overlay.playerRail"]
                .waitForNonExistence(timeout: 1)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["overlay.industryRail"]
                .waitForExistence(timeout: 1)
        )

        industryToggle.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["overlay.industryRail"]
                .waitForNonExistence(timeout: 1)
        )
        XCTAssertEqual(industryToggle.value as? String, "已收起")
    }

    @MainActor
    func testTabletAuthoritativeRailsRemainPermanent() throws {
        let app = launchLocalFixture()
        guard app.windows.firstMatch.frame.width >= 1_000 else {
            throw XCTSkip("iPad-only rail behavior")
        }
        XCTAssertFalse(app.buttons["real.playerRail.toggle"].exists)
        XCTAssertFalse(app.buttons["real.industryRail.toggle"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["match.playerRail.content"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["match.industryRail.content"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["industry.medallion.industry-cotton"].exists)
    }

    @MainActor
    func testPhoneMapPansAndExpandedDrawersStayClearOfTheHand() throws {
        let app = launchLocalFixture()
        guard app.windows.firstMatch.frame.width < 1_000 else {
            throw XCTSkip("iPhone-only map and drawer behavior")
        }

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
}
