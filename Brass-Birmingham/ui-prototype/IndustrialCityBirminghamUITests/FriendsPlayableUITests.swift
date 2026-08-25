import XCTest

final class FriendsPlayableUITests: XCTestCase {
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
        XCTAssertTrue(app.staticTexts["real.turn"].exists)
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
}
