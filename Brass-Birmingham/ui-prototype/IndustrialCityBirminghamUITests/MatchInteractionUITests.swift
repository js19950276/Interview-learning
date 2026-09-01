import XCTest

final class MatchInteractionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = MainActor.assumeIsolated {
            XCUIDevice.shared.orientation = .landscapeLeft
            let launchedApp = XCUIApplication()
            launchedApp.launchArguments = ["-ui-testing"]
            launchedApp.launch()
            return launchedApp
        }
    }

    @MainActor
    func testCardSelectionAndTransientOverlaysAreMutuallyExclusive() throws {
        enterMatch()

        let firstCard = app.buttons["hand.card.card-birmingham"]
        let secondCard = app.buttons["hand.card.card-coventry"]
        XCTAssertTrue(firstCard.waitForExistence(timeout: 3))
        XCTAssertTrue(secondCard.exists)

        firstCard.tap()
        XCTAssertTrue(firstCard.isSelected)

        secondCard.tap()
        XCTAssertTrue(secondCard.isSelected)
        XCTAssertFalse(firstCard.isSelected)

        if app.windows.firstMatch.frame.width >= 1_000 {
            XCTAssertTrue(app.descendants(matching: .any)["match.playerRail"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["match.industryRail"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["market.coal"].exists)
            XCTAssertFalse(app.buttons["market.expand"].exists)
        } else {
            app.buttons["match.playerRail"].tap()
            assertOnlyOverlay("overlay.playerRail")

            app.buttons["match.industryRail"].tap()
            assertOnlyOverlay("overlay.industryRail")

            app.buttons["market.expand"].tap()
            assertOnlyOverlay("overlay.resourceMarket")
        }

        app.buttons["match.actionButton"].tap()
        assertOnlyOverlay("overlay.actionGrid")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'action.'")).count, 8)
    }

    @MainActor
    func testTabletShowsEightReadableCardsAndFullMarket() {
        enterMatch()

        let hand = app.descendants(matching: .any)["match.hand"]
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'hand.card.'"))
        XCTAssertEqual(cards.count, 8)

        let handFrame = hand.frame.insetBy(dx: -1, dy: -24)
        let frames = (0..<cards.count)
            .map { cards.element(boundBy: $0).frame }
            .sorted { $0.minX < $1.minX }

        for frame in frames {
            XCTAssertTrue(handFrame.contains(frame), "hand=\(hand.frame), card=\(frame)")
            XCTAssertGreaterThanOrEqual(frame.width, 44)
            XCTAssertGreaterThanOrEqual(frame.height, 44)
        }
        if app.windows.firstMatch.frame.width >= 1_000 {
            for index in 0..<(frames.count - 1) {
                XCTAssertLessThanOrEqual(frames[index].maxX, frames[index + 1].minX + 0.5)
            }
            XCTAssertTrue(app.descendants(matching: .any)["market.coal"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["market.iron"].exists)
            XCTAssertFalse(app.buttons["market.expand"].exists)
        } else {
            let marketExpand = app.buttons["market.expand"]
            XCTAssertTrue(marketExpand.exists)
            XCTAssertFalse(marketExpand.label.isEmpty)
        }
    }

    @MainActor
    func testMapBackgroundTapDismissesTransientOverlay() {
        enterMatch()

        if app.windows.firstMatch.frame.width >= 1_000 {
            app.buttons["match.actionButton"].tap()
            let actionGrid = app.descendants(matching: .any)["overlay.actionGrid"]
            XCTAssertTrue(actionGrid.waitForExistence(timeout: 1))

            let map = app.descendants(matching: .any)["match.map"]
            let walsallBurtonRoute = map.coordinate(
                withNormalizedOffset: CGVector(dx: 0.60, dy: 0.30)
            )
            walsallBurtonRoute.tap()
            XCTAssertTrue(actionGrid.exists, "A route tap must not be treated as background")

            let emptyNorthMapArea = map.coordinate(
                withNormalizedOffset: CGVector(dx: 0.60, dy: 0.10)
            )
            emptyNorthMapArea.tap()
            XCTAssertTrue(actionGrid.waitForNonExistence(timeout: 2))
            return
        }

        let buildCard = app.buttons["hand.card.card-birmingham"]
        XCTAssertTrue(buildCard.waitForExistence(timeout: 2))
        buildCard.tap()
        app.buttons["match.actionButton"].tap()
        app.buttons["action.build"].tap()

        let birminghamTarget = app.buttons["map.target.birmingham"]
        XCTAssertTrue(birminghamTarget.waitForExistence(timeout: 2))

        let map = app.descendants(matching: .any)["match.map"]
        XCTAssertTrue(map.exists)

        app.buttons["match.playerRail"].tap()
        let drawer = app.descendants(matching: .any)["overlay.playerRail"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 1))

        let birminghamLocation = map.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.57)
        )
        birminghamLocation.tap()
        XCTAssertTrue(
            waitForEnabled(app.buttons["action.confirm"]),
            "The Birmingham map point must reach the same selected build draft"
        )
        XCTAssertTrue(drawer.exists, "A map target tap must not be treated as background")

        map.swipeLeft()
        XCTAssertTrue(drawer.exists, "Panning the map must not dismiss the overlay")

        map.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)).tap()

        XCTAssertFalse(drawer.waitForExistence(timeout: 1))
    }

    @MainActor
    func testConfirmationPanelDisablesIncompleteFlowAndCancelKeepsCardSelected() {
        enterMatch()

        let card = app.buttons["hand.card.card-birmingham"]
        card.tap()
        XCTAssertTrue(card.isSelected)

        app.buttons["match.actionButton"].tap()
        app.buttons["action.build"].tap()

        let confirmation = app.descendants(matching: .any)["action.confirmation"]
        let confirmButton = app.buttons["action.confirm"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 1))
        XCTAssertFalse(confirmButton.isEnabled)

        app.buttons["action.cancel"].tap()

        XCTAssertFalse(confirmation.exists)
        XCTAssertTrue(card.isSelected)

        app.buttons["match.actionButton"].tap()
        app.buttons["action.loan"].tap()

        XCTAssertTrue(confirmation.waitForExistence(timeout: 1))
        XCTAssertTrue(confirmButton.isEnabled)
    }

    @MainActor
    func testBuildActionShowsContextAndCancelKeepsSelectedCard() {
        relaunch(arguments: ["-local-ui-fixture"])
        XCTAssertTrue(app.descendants(matching: .any)["real.match"].waitForExistence(timeout: 8))

        let card = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'hand.card.'")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        let cardIdentifier = card.identifier
        let selectedCard = app.buttons[cardIdentifier]
        card.tap()
        XCTAssertTrue(waitForValue(selectedCard, containing: "行动牌已选中"))

        let build = app.buttons["action.build"]
        XCTAssertTrue(build.waitForExistence(timeout: 2))
        build.tap()

        let context = app.descendants(matching: .any)["action.context"]
        XCTAssertTrue(context.waitForExistence(timeout: 2))
        XCTAssertTrue(waitForLabel(context, containing: "行动 1/1"))
        XCTAssertTrue(waitForLabel(context, containing: "建造"))

        app.buttons["action.context.cancel"].tap()

        XCTAssertTrue(context.waitForNonExistence(timeout: 2))
        XCTAssertTrue(waitForValue(selectedCard, containing: "行动牌已选中"))
    }

    @MainActor
    func testScoutTappingSelectedDiscardKeepsActionCardAndReopensDiscardChoice() {
        relaunch(arguments: ["-local-ui-fixture"])
        XCTAssertTrue(app.descendants(matching: .any)["real.match"].waitForExistence(timeout: 8))

        let firstHandCard = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'hand.card.'")
        ).firstMatch
        XCTAssertTrue(firstHandCard.waitForExistence(timeout: 3))
        let actionCardIdentifier = firstHandCard.identifier
        let actionCard = app.buttons[actionCardIdentifier]
        XCTAssertTrue(actionCard.waitForExistence(timeout: 3))

        actionCard.tap()
        XCTAssertTrue(waitForValue(actionCard, containing: "行动牌已选中"))

        let scout = app.buttons["action.scout"]
        XCTAssertTrue(scout.waitForExistence(timeout: 2))
        scout.tap()

        guard let firstDiscardIdentifier = waitForHandCardIdentifier(
            valueContaining: "可选作侦察弃牌",
            excluding: [actionCardIdentifier]
        ) else {
            XCTFail("Expected a first scout discard card")
            return
        }
        let firstDiscard = app.buttons[firstDiscardIdentifier]
        guard let secondDiscardIdentifier = waitForHandCardIdentifier(
            valueContaining: "可选作侦察弃牌",
            excluding: [actionCardIdentifier, firstDiscardIdentifier]
        ) else {
            XCTFail("Expected a second scout discard card")
            return
        }
        let secondDiscard = app.buttons[secondDiscardIdentifier]

        XCTAssertTrue(waitForValue(firstDiscard, containing: "可选作侦察弃牌"))
        XCTAssertTrue(waitForValue(secondDiscard, containing: "可选作侦察弃牌"))
        firstDiscard.tap()
        secondDiscard.tap()

        XCTAssertTrue(waitForValue(actionCard, containing: "行动牌已选中"))
        XCTAssertTrue(waitForValue(firstDiscard, containing: "侦察弃牌已选中"))
        XCTAssertTrue(waitForValue(secondDiscard, containing: "侦察弃牌已选中"))
        XCTAssertTrue(waitForEnabled(app.buttons["action.confirm"]))

        firstDiscard.tap()

        XCTAssertTrue(waitForValue(actionCard, containing: "行动牌已选中"))
        XCTAssertTrue(waitForValue(firstDiscard, containing: "可选作侦察弃牌"))
        XCTAssertTrue(waitForValue(secondDiscard, containing: "侦察弃牌已选中"))
        XCTAssertTrue(app.descendants(matching: .any)["action.confirmation"].waitForNonExistence(timeout: 2))
        let confirm = app.buttons["action.confirm"]
        if confirm.exists {
            XCTAssertFalse(confirm.isEnabled)
        }
    }

    @MainActor
    func testBuildAndTwoRailPreviewsUseMapTargetsAndCancelKeepsCardSelected() {
        relaunchForRailFixture()
        enterMatch()

        let card = app.buttons["hand.card.card-birmingham"]
        card.tap()

        app.buttons["match.actionButton"].tap()
        app.buttons["action.build"].tap()

        let buildTarget = app.buttons["flow.target.birmingham"]
        XCTAssertTrue(buildTarget.waitForExistence(timeout: 2))
        buildTarget.tap()
        let buildDetail = app.descendants(matching: .any)["action.detail.0"]
        XCTAssertTrue(buildDetail.waitForExistence(timeout: 1))
        XCTAssertTrue(waitForLabel(buildDetail, containing: "Birmingham"), "detail=\(buildDetail.label)")
        XCTAssertTrue(waitForEnabled(app.buttons["action.confirm"]))

        app.buttons["action.cancel"].tap()
        XCTAssertTrue(card.isSelected)

        app.buttons["match.actionButton"].tap()
        app.buttons["action.network"].tap()

        let countControl = app.segmentedControls["network.count"]
        XCTAssertTrue(countControl.waitForExistence(timeout: 1))
        countControl.buttons["2 条"].tap()

        let firstRoute = app.buttons["flow.target.birmingham-walsall"]
        XCTAssertTrue(firstRoute.waitForExistence(timeout: 2))
        firstRoute.tap()

        let secondRoute = app.buttons["flow.target.walsall-cannock"]
        XCTAssertTrue(secondRoute.waitForExistence(timeout: 2))
        secondRoute.tap()

        XCTAssertTrue(waitForEnabled(app.buttons["action.confirm"]))
        XCTAssertTrue(app.descendants(matching: .any)["action.detail.0"].label.contains("Birmingham"))
        XCTAssertTrue(app.descendants(matching: .any)["action.detail.1"].label.contains("Walsall"))

        app.buttons["action.cancel"].tap()
        XCTAssertTrue(card.isSelected)
    }

    @MainActor
    func testSteamInspiredRailsPreserveResponsiveInteraction() {
        relaunch(arguments: ["-ui-testing", "-local-ui-fixture"])

        if app.windows.firstMatch.frame.width >= 1_000 {
            XCTAssertTrue(app.descendants(matching: .any)["match.playerRail.content"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.descendants(matching: .any)["match.industryRail.content"].exists)
            XCTAssertFalse(app.buttons["real.playerRail.toggle"].exists)
            XCTAssertFalse(app.buttons["real.industryRail.toggle"].exists)
            return
        }

        let playerToggle = app.buttons["real.playerRail.toggle"]
        let industryToggle = app.buttons["real.industryRail.toggle"]
        XCTAssertTrue(playerToggle.waitForExistence(timeout: 8))
        XCTAssertTrue(industryToggle.exists)
        XCTAssertGreaterThanOrEqual(playerToggle.frame.width, 44)
        XCTAssertGreaterThanOrEqual(playerToggle.frame.height, 44)
        XCTAssertGreaterThanOrEqual(industryToggle.frame.width, 44)
        XCTAssertGreaterThanOrEqual(industryToggle.frame.height, 44)

        playerToggle.tap()
        XCTAssertTrue(app.descendants(matching: .any)["overlay.playerRail"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.descendants(matching: .any)["overlay.industryRail"].exists)

        industryToggle.tap()
        XCTAssertFalse(app.descendants(matching: .any)["overlay.playerRail"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["overlay.industryRail"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testDevelopTwoIndustriesAndSellOneMerchantOptionDriveConfirmation() {
        enterMatch()

        let card = app.buttons["hand.card.card-birmingham"]
        card.tap()

        app.buttons["match.actionButton"].tap()
        app.buttons["action.develop"].tap()

        let coal = app.buttons["industry.select.industry-coal"]
        let iron = app.buttons["industry.select.industry-iron"]
        XCTAssertTrue(coal.waitForExistence(timeout: 2))
        XCTAssertTrue(iron.exists)
        XCTAssertGreaterThanOrEqual(coal.frame.width, 44)
        XCTAssertGreaterThanOrEqual(coal.frame.height, 44)

        coal.tap()
        iron.tap()

        let selectionCount = app.staticTexts["develop.selectionCount"]
        XCTAssertTrue(selectionCount.waitForExistence(timeout: 1))
        XCTAssertEqual(selectionCount.label, "2/2")
        XCTAssertTrue(app.descendants(matching: .any)["action.detail.0"].label.contains("煤矿"))
        XCTAssertTrue(app.descendants(matching: .any)["action.detail.1"].label.contains("炼铁厂"))
        XCTAssertEqual(app.descendants(matching: .any)["action.delta.iron"].label, "铁变化 -2")
        XCTAssertTrue(waitForEnabled(app.buttons["action.confirm"]))

        app.buttons["action.cancel"].tap()
        app.buttons["match.actionButton"].tap()
        app.buttons["action.sell"].tap()

        let cotton = app.buttons["industry.select.industry-cotton"]
        XCTAssertTrue(cotton.waitForExistence(timeout: 2))
        cotton.tap()

        let merchantCard = app.descendants(matching: .any)["sell.merchantCard.industry-cotton"]
        XCTAssertTrue(merchantCard.waitForExistence(timeout: 1))

        let option = app.buttons["sell.option.sell-cotton-oxford"]
        XCTAssertTrue(option.exists)
        XCTAssertGreaterThanOrEqual(option.frame.width, 44)
        XCTAssertGreaterThanOrEqual(option.frame.height, 44)
        option.tap()

        XCTAssertTrue(app.descendants(matching: .any)["action.detail.0"].label.contains("Oxford"))
        XCTAssertEqual(app.descendants(matching: .any)["action.delta.money"].label, "金钱变化 +8")
        XCTAssertEqual(app.descendants(matching: .any)["action.income"].label, "收入从 5 变为 6")
        XCTAssertTrue(waitForEnabled(app.buttons["action.confirm"]))
    }

    @MainActor
    func testLoanScoutAndPassConfirmationsStayOffTheMapAndSupportCancel() {
        enterMatch()

        let actionCard = app.buttons["hand.card.card-birmingham"]
        actionCard.tap()

        openAction("loan")
        XCTAssertTrue(app.descendants(matching: .any)["action.confirmation"].waitForExistence(timeout: 1))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'flow.target.'")).count, 0)
        XCTAssertEqual(app.descendants(matching: .any)["action.beforeAfter.money"].label, "金钱从 17 变为 47")
        XCTAssertEqual(app.descendants(matching: .any)["action.beforeAfter.income"].label, "收入从 5 变为 2")
        XCTAssertTrue(waitForEnabled(app.buttons["action.confirm"]))
        app.buttons["action.cancel"].tap()
        XCTAssertTrue(actionCard.isSelected)

        openAction("scout")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'flow.target.'")).count, 0)
        XCTAssertFalse(app.buttons["action.confirm"].isEnabled)

        let firstExtra = app.buttons["hand.card.card-walsall"]
        let secondExtra = app.buttons["hand.card.card-iron"]
        firstExtra.tap()
        secondExtra.tap()

        XCTAssertTrue(actionCard.isSelected)
        XCTAssertTrue(firstExtra.isSelected)
        XCTAssertTrue(secondExtra.isSelected)
        XCTAssertEqual(
            app.descendants(matching: .any)["scout.wildcard.0"].label,
            "地点万能牌 · Walsall"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["scout.wildcard.1"].label,
            "产业万能牌 · Iron Works"
        )
        XCTAssertTrue(waitForEnabled(app.buttons["action.confirm"]))
        app.buttons["action.cancel"].tap()
        XCTAssertTrue(actionCard.isSelected)

        openAction("pass")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'flow.target.'")).count, 0)
        XCTAssertEqual(app.descendants(matching: .any)["pass.discard"].label, "弃掉 1 张所选卡牌")
        XCTAssertEqual(app.descendants(matching: .any)["pass.actionAdvance"].label, "行动计数从 1 变为 2")
        XCTAssertTrue(waitForEnabled(app.buttons["action.confirm"]))
        app.buttons["action.cancel"].tap()
        XCTAssertTrue(actionCard.isSelected)
    }

    @MainActor
    func testAcceptedEventShowsAnimatedResourceAndUpdatedEffects() {
        relaunch(arguments: ["-ui-testing", "-resource-animation-hold-ms", "3500"])
        enterMatch()
        confirmBuildAction()

        let motion = app.descendants(matching: .any)["event.motion.animated"]
        XCTAssertTrue(motion.waitForExistence(timeout: 2))
        XCTAssertEqual(motion.value as? String, "source")
        let sourceFrame = motion.frame
        let reachedDestination = XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == 'destination'"),
                    object: motion
                )
            ],
            timeout: 6
        ) == .completed
        XCTAssertTrue(reachedDestination)
        XCTAssertNotEqual(sourceFrame, motion.frame)

        let accepted = app.descendants(matching: .any)["event.accepted"]
        XCTAssertTrue(accepted.waitForExistence(timeout: 3))
        XCTAssertTrue(motion.exists)
        XCTAssertTrue(app.descendants(matching: .any)["event.effect.2"].label.contains("产业板块已翻面"))
        XCTAssertTrue(app.descendants(matching: .any)["event.effect.3"].label.contains("收入：0 → 1"))
        XCTAssertTrue(app.descendants(matching: .any)["event.effect.4"].label.contains("行动：1 → 2"))
        XCTAssertTrue(app.descendants(matching: .any)["market.coal"].label.contains("剩余 6"))
        XCTAssertTrue(app.descendants(matching: .any)["match.header"].label.contains("行动 2"))
        XCTAssertTrue(app.descendants(matching: .any)["match.header"].label.contains("收入 +1"))
        XCTAssertEqual(app.descendants(matching: .any)["industry.flip.industry-coal"].value as? String, "已翻面")
        XCTAssertTrue(motion.label.contains("coal-market"))
        XCTAssertTrue(motion.label.contains("birmingham"))
    }

    @MainActor
    func testAcceptedEventUsesReducedMotionAlternative() {
        relaunch(arguments: ["-ui-testing", "-reduce-motion", "YES"])
        enterMatch()
        confirmBuildAction()

        XCTAssertTrue(app.descendants(matching: .any)["event.accepted"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["event.motion.reduced"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["event.motion.animated"].exists)
    }

    @MainActor
    func testRejectedEventShowsRecoveryAndKeepsEditableDraft() {
        relaunch(arguments: ["-ui-testing", "-invalid-action-target"])
        enterMatch()

        let card = app.buttons["hand.card.card-birmingham"]
        card.tap()
        openAction("build")
        app.buttons["flow.target.birmingham"].tap()
        app.buttons["action.confirm"].tap()

        let rejected = app.descendants(matching: .any)["event.rejected"]
        XCTAssertTrue(rejected.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["event.rejection.reason"].label.contains("invalid-target"))
        XCTAssertFalse(app.descendants(matching: .any)["event.rejection.recovery"].label.isEmpty)
        XCTAssertEqual(rejected.value as? String, "VoiceOver焦点，草稿已保留")
        XCTAssertTrue(app.descendants(matching: .any)["action.confirmation"].exists)
        XCTAssertTrue(card.isSelected)
    }

    @MainActor
    func testRejectedActionFixtureLaunchesDeterministicNamedState() {
        relaunch(arguments: ["-ui-testing", "-fixture", "rejectedAction"])

        let rejected = app.descendants(matching: .any)["event.rejected"]
        XCTAssertTrue(rejected.waitForExistence(timeout: 4))
        XCTAssertFalse(rejected.label.isEmpty)
        XCTAssertTrue(rejected.label.contains("行动未接受"))
        XCTAssertTrue(app.descendants(matching: .any)["action.confirmation"].exists)
        assertAccessibleControl(app.buttons["action.confirm"])
    }

    @MainActor
    func testDisconnectedFixtureLaunchesNamedMatchState() {
        relaunch(arguments: ["-ui-testing", "-fixture", "disconnected"])

        let playerRail = app.descendants(matching: .any)["match.playerRail"]
        XCTAssertTrue(playerRail.waitForExistence(timeout: 4))
        XCTAssertTrue(playerRail.label.contains("Bessemer"))
        XCTAssertTrue(playerRail.label.contains("离线"))
        assertAccessibleControl(app.buttons["match.actionButton"])
    }

    @MainActor
    func testLaunchPreferencesExposeReduceMotionAndColorAssistStates() {
        relaunch(arguments: [
            "-ui-testing",
            "-fixture", "players4",
            "-reduce-motion", "YES",
            "-color-assist", "YES"
        ])

        let playerRail = app.descendants(matching: .any)["match.playerRail"]
        XCTAssertTrue(playerRail.waitForExistence(timeout: 4))
        XCTAssertEqual(playerRail.value as? String, "4 位玩家")
        for shape in ["菱形标记", "三角形标记", "圆形标记", "方形标记"] {
            XCTAssertTrue(playerRail.label.contains(shape))
        }
        confirmBuildAction()
        XCTAssertTrue(app.descendants(matching: .any)["event.motion.reduced"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["event.motion.animated"].exists)
        assertAccessibleControl(app.buttons["match.actionButton"])
    }

    @MainActor
    func testColorAssistCanBeDisabledWithoutExposingShapeNames() {
        relaunch(arguments: [
            "-ui-testing",
            "-fixture", "players4",
            "-color-assist", "NO"
        ])

        let playerRail = app.descendants(matching: .any)["match.playerRail"]
        XCTAssertTrue(playerRail.waitForExistence(timeout: 4))
        XCTAssertEqual(playerRail.value as? String, "4 位玩家")
        XCTAssertFalse(playerRail.label.contains("标记"))

        if app.buttons["match.playerRail"].exists {
            app.buttons["match.playerRail"].tap()
            let drawer = app.descendants(matching: .any)["overlay.playerRail"]
            XCTAssertTrue(drawer.waitForExistence(timeout: 2))
            XCTAssertEqual(
                drawer.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '标记'")).count,
                0
            )
            for colorName in ["琥珀色", "深红色", "青绿色", "紫罗兰色"] {
                XCTAssertEqual(
                    drawer.descendants(matching: .any).matching(
                        NSPredicate(format: "label CONTAINS %@", colorName)
                    ).count,
                    1,
                    "Expected exactly one drawer player labeled \(colorName)"
                )
            }
        }
    }

    @MainActor
    func testInvalidTargetLaunchArgumentIsIgnoredOutsideUITesting() {
        relaunch(arguments: ["-invalid-action-target"])

        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 3))
        app.buttons["home.online"].tap()
        XCTAssertTrue(app.staticTexts["在线房间暂未开放"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["online.create"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["event.rejected"].exists)
    }

    @MainActor
    private func enterMatch() {
        app.buttons["home.online"].tap()
        XCTAssertTrue(app.buttons["online.create"].waitForExistence(timeout: 2))
        app.buttons["online.create"].tap()

        let startButton = app.buttons["lobby.start"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 2))
        app.scrollViews.firstMatch.swipeUp()
        app.scrollViews.firstMatch.swipeUp()
        startButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["match.shell"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func relaunchForRailFixture() {
        relaunch(arguments: ["-ui-testing", "-rail-fixture"])
    }

    @MainActor
    private func relaunch(arguments: [String]) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
    }

    @MainActor
    private func confirmBuildAction() {
        app.buttons["hand.card.card-birmingham"].tap()
        openAction("build")
        let target = app.buttons["flow.target.birmingham"]
        XCTAssertTrue(target.waitForExistence(timeout: 2))
        target.tap()
        let confirm = app.buttons["action.confirm"]
        XCTAssertTrue(waitForEnabled(confirm, timeout: 5))
        confirm.tap()
    }

    @MainActor
    private func openAction(_ action: String) {
        app.buttons["match.actionButton"].tap()
        let actionButton = app.buttons["action.\(action)"]
        let isReady = XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == true AND hittable == true"),
                    object: actionButton
                )
            ],
            timeout: 5
        ) == .completed
        XCTAssertTrue(isReady, "Action button action.\(action) did not become hittable")
        actionButton.tap()
    }

    @MainActor
    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval = 2) -> Bool {
        XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)],
            timeout: timeout
        ) == .completed
    }

    @MainActor
    private func waitForLabel(
        _ element: XCUIElement,
        containing text: String,
        timeout: TimeInterval = 2
    ) -> Bool {
        XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label CONTAINS %@", text),
                    object: element
                )
            ],
            timeout: timeout
        ) == .completed
    }

    @MainActor
    private func waitForValue(
        _ element: XCUIElement,
        containing text: String,
        timeout: TimeInterval = 2
    ) -> Bool {
        XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value CONTAINS %@", text),
                    object: element
                )
            ],
            timeout: timeout
        ) == .completed
    }

    @MainActor
    private func waitForHandCardIdentifier(
        valueContaining text: String,
        excluding excludedIdentifiers: Set<String> = [],
        timeout: TimeInterval = 3
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        let cards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'hand.card.'")
        )
        repeat {
            for index in 0..<cards.count {
                let card = cards.element(boundBy: index)
                guard card.exists, !excludedIdentifiers.contains(card.identifier) else { continue }
                let value = card.value as? String ?? ""
                if value.contains(text) {
                    return card.identifier
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }

    @MainActor
    private func assertOnlyOverlay(_ expectedIdentifier: String) {
        let identifiers = [
            "overlay.playerRail",
            "overlay.industryRail",
            "overlay.resourceMarket",
            "overlay.actionGrid"
        ]

        for identifier in identifiers {
            let element = app.descendants(matching: .any)[identifier]
            if identifier == expectedIdentifier {
                XCTAssertTrue(element.waitForExistence(timeout: 1), "Missing \(identifier)")
            } else {
                XCTAssertFalse(element.exists, "Expected \(identifier) to be closed")
            }
        }
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
