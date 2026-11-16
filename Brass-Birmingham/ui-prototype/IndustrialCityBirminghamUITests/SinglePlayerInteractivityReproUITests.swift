import XCTest

/// 真机复现第二阶段:进局后 UI 必须可交互。Xs Max 真机曾出现进局后
/// 按键与地图手势全部无响应(2026-10-29):根因是 syncStatus 卡在
/// .connecting,submission.blocker 全屏遮罩挡掉所有触摸。
final class SinglePlayerInteractivityReproUITests: XCTestCase {
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
    func testMatchControlsRespondAfterEntry() throws {
        let app = XCUIApplication()
        app.launch()
        activeApp = app

        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 5))
        app.buttons["home.single"].tap()
        XCTAssertTrue(app.buttons["single.start"].waitForExistence(timeout: 5))
        app.buttons["single.start"].tap()
        // 对局强制横屏:开局即转横屏,避免进局后旋转竞态把手牌挤出屏幕。
        XCUIDevice.shared.orientation = .landscapeLeft

        let matchShell = app.descendants(matching: .any)["real.match"]
        let errorText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "开局失败")
        ).firstMatch
        let deadline = Date().addingTimeInterval(30)
        while !matchShell.exists, Date() < deadline {
            XCTAssertFalse(errorText.exists, "开局报错:\(errorText.label)")
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(matchShell.exists, "30 秒内未进入对局")

        // 1) 回归主断言:单人进局后不得出现"对局同步中"遮罩(它挡掉全部触摸)。
        let blocker = app.descendants(matching: .any)["submission.blocker"]
        XCTAssertFalse(
            blocker.exists,
            "submission.blocker 出现:syncStatus 未到 .connected(遮罩文本:\(blocker.label))"
        )

        // 2) 手牌必须出现且首卡可点开动作选择(真实视图容器是 real.hand,
        //    内层 HandView 是 match.hand)。
        let hand = app.descendants(matching: .any)["real.hand"].firstMatch
        let handFallback = app.descendants(matching: .any)["match.hand"].firstMatch
        XCTAssertTrue(
            hand.waitForExistence(timeout: 10) || handFallback.waitForExistence(timeout: 5),
            "手牌未出现"
        )
        XCUIDevice.shared.orientation = .landscapeLeft
        let firstCard = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'hand.card.'")
        ).firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 5), "手牌卡按钮未出现")
        // 等卡片真正可命中(旋转布局稳定)再点。
        let hittableDeadline = Date().addingTimeInterval(10)
        while !firstCard.isHittable, Date() < hittableDeadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(firstCard.isHittable, "手牌卡不可命中(布局异常或被遮挡)")
        // 开局行动顺序按种子随机洗牌:先手可能是 AI,其每个事件都会重置选卡状态。
        // 因此"点卡→动作网格出现"要作为整体在时限内重试,直到轮到本机玩家。
        let actionGrid = app.descendants(matching: .any)["overlay.actionGrid"]
        var gridShown = false
        let interactDeadline = Date().addingTimeInterval(90)
        while Date() < interactDeadline {
            firstCard.tap()
            if actionGrid.waitForExistence(timeout: 2) {
                gridShown = true
                break
            }
            // 选卡可能被 AI 事件重置;也可能当前卡已选中(再点等于取消),统一等下轮重试。
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(gridShown, "90 秒内始终无法完成 点卡→动作网格 交互")

        // 3) 动作网格里的关闭按钮也必须可响应(点完网格收起)。
        app.buttons["action.close"].tap()
        let gridGoneDeadline = Date().addingTimeInterval(3)
        while actionGrid.exists, Date() < gridGoneDeadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertFalse(actionGrid.exists, "点击关闭按钮后动作网格未收起")

        // 3) 地图捏合必须改变缩放读数。
        let map = app.descendants(matching: .any)["match.map"].firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5), "地图未出现")
        let before = (map.value as? String) ?? ""
        map.pinch(withScale: 2.0, velocity: 1)
        let after = (map.value as? String) ?? ""
        XCTAssertNotEqual(before, after, "捏合后地图缩放读数无变化: before=\(before) after=\(after)")
    }
}
