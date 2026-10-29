import XCTest

/// UI 冒烟测试：能从菜单开局进入对局界面。
/// 设 POKER_UI_DUMP_DIR 环境变量时把对局截图写到该目录（供视觉检查，日常跑不必设）。
final class PokerAppUITests: XCTestCase {
    func testStartCashGameShowsTable() throws {
        let app = XCUIApplication()
        // xcodebuild 的环境变量不自动透传给测试进程，显式转发以支持截图调试
        if let dir = ProcessInfo.processInfo.environment["POKER_UI_DUMP_DIR"] {
            app.launchEnvironment["POKER_UI_DUMP_DIR"] = dir
        }
        app.launch()

        let start = app.buttons["开始游戏"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "菜单里应能看到开始游戏按钮")
        if !start.isHittable { app.swipeUp() }
        start.tap()

        // 进入对局界面：中央出现「底池 N」
        let pot = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '底池'")).firstMatch
        XCTAssertTrue(pot.waitForExistence(timeout: 5), "开局后应显示底池")

        try dumpScreenshot("game-screen")
    }

    private func dumpScreenshot(_ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["POKER_UI_DUMP_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
