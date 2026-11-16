import XCTest

/// 真机复现回归:单人挑战点开局后既不能弹"开局失败",也必须在时限内进入真实对局。
/// 纯真机路径:不带 -ui-testing / -fixture,走 packagedRules 目录 + 真实会话工厂。
final class SinglePlayerStartReproUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSinglePlayerChallengeStartsWithoutError() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 5))
        app.buttons["home.single"].tap()
        XCTAssertTrue(app.buttons["single.start"].waitForExistence(timeout: 5))
        app.buttons["single.start"].tap()

        let errorText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "开局失败")
        ).firstMatch
        let matchShell = app.descendants(matching: .any)["real.match"]

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if errorText.exists {
                XCTFail("单人挑战开局报错:\(errorText.label)")
                return
            }
            if matchShell.exists { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("开局 30 秒内既未报错也未进入对局(real.match 未出现)")
    }
}
