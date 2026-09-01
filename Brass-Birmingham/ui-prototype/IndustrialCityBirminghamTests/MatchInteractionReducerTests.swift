import CoreGraphics
import Testing
@testable import IndustrialCityBirmingham

@MainActor
struct MatchInteractionReducerTests {
    @Test func selectingCardStoresItsID() {
        let reducer = MatchInteractionReducer()

        reducer.selectCard("card-birmingham")

        #expect(reducer.selectedCardID == "card-birmingham")
    }

    @Test func selectingSecondCardReplacesFirstAndClearsDraft() {
        let reducer = MatchInteractionReducer()
        reducer.selectCard("card-birmingham")
        reducer.selectAction(.build)

        reducer.selectCard("card-coventry")

        #expect(reducer.selectedCardID == "card-coventry")
        #expect(reducer.selectedAction == nil)
        #expect(reducer.flow == .idle)
    }

    @Test func openingMarketAfterPlayerDrawerLeavesOnlyMarketOpen() {
        let reducer = MatchInteractionReducer()
        reducer.toggleOverlay(.playerRail)

        reducer.toggleOverlay(.resourceMarket)

        #expect(reducer.overlay == .resourceMarket)
    }

    @Test func selectingActionClosesTransientOverlay() {
        let reducer = MatchInteractionReducer()
        reducer.toggleOverlay(.actionGrid)

        reducer.selectAction(.network)

        #expect(reducer.overlay == nil)
        #expect(reducer.selectedAction == .network)
        #expect(reducer.flow == .network(NetworkDraft()))
    }

    @Test func cancelingActionKeepsSelectedCard() {
        let reducer = MatchInteractionReducer()
        reducer.selectCard("card-birmingham")
        reducer.selectAction(.sell)

        reducer.cancelFlow()

        #expect(reducer.selectedCardID == "card-birmingham")
        #expect(reducer.selectedAction == nil)
        #expect(reducer.flow == .idle)
    }

    @Test func acceptedVersionResetClearsCardActionFlowAndOverlay() {
        let reducer = MatchInteractionReducer()
        reducer.selectCard("card-birmingham")
        reducer.toggleOverlay(.actionGrid)
        reducer.selectAction(.build)

        reducer.resetSelection()

        #expect(reducer.selectedCardID == nil)
        #expect(reducer.selectedAction == nil)
        #expect(reducer.overlay == nil)
        #expect(reducer.flow == .idle)
    }

    @Test func dismissingOverlayAfterMapBackgroundTapClosesTransientLayer() {
        let reducer = MatchInteractionReducer()
        reducer.toggleOverlay(.playerRail)

        reducer.dismissOverlay()

        #expect(reducer.overlay == nil)
    }

    @Test func authoritativeMapTargetResolverMapsOnlyDirectMapChoices() {
        let choices: [GameCore.LegalChoice] = [
            .init(
                id: "build:birmingham:3",
                label: "伯明翰",
                value: .buildTarget(locationID: "birmingham", slotIndex: 3)
            ),
            .init(
                id: "route:birmingham-oxford",
                label: "伯明翰—牛津",
                value: .route(id: "birmingham-oxford")
            ),
            .init(
                id: "merchant:oxford-1",
                label: "牛津 · 任意制成品 · 收入 +2",
                value: .merchant(id: "oxford-1")
            ),
            .init(
                id: "placement:sale-a",
                label: "伯明翰 · 棉纺厂",
                value: .industryPlacement(id: "sale-a")
            ),
            .init(
                id: "tile:cotton-1",
                label: "棉纺厂",
                value: .industryTile(id: "cotton-1")
            ),
            .init(
                id: "source:beer:industry:beer-a",
                label: "德比 · 自己的啤酒厂",
                value: .resourceSource(.industry(placementID: "beer-a"))
            ),
        ]

        #expect(
            AuthoritativeMapTargetResolver.highlightedIDs(from: choices)
                == ["birmingham", "birmingham-oxford", "oxford-1", "beer-a"]
        )
        #expect(
            AuthoritativeMapTargetResolver.choice(for: "oxford-1", in: choices)?.value
                == .merchant(id: "oxford-1")
        )
        #expect(AuthoritativeMapTargetResolver.choice(for: "sale-a", in: choices) == nil)
        #expect(AuthoritativeMapTargetResolver.choice(for: "cotton-1", in: choices) == nil)
        #expect(
            AuthoritativeMapTargetResolver.choice(for: "beer-a", in: choices)?.value
                == .resourceSource(.industry(placementID: "beer-a"))
        )
    }

    @Test func tabletHandFitsEightReadableCardsInNarrowAvailableWidth() {
        let layout = HandView.layout(
            availableWidth: 578,
            cardCount: 8,
            formFactor: .tablet
        )

        #expect(layout.cardWidth >= 44)
        #expect(layout.totalWidth <= 578)
    }

    @Test func phoneHandUsesCompactOverlappedDockForEightCards() {
        let layout = HandView.layout(
            availableWidth: 764,
            cardCount: 8,
            formFactor: .phone
        )

        #expect(layout.cardWidth <= 78)
        #expect(layout.spacing < 0)
        #expect(layout.totalWidth <= 764)
    }

    @Test(arguments: [
        (GameAction.build, "建造"),
        (GameAction.network, "铺设"),
        (GameAction.develop, "研发"),
        (GameAction.sell, "出售"),
        (GameAction.loan, "贷款"),
        (GameAction.scout, "侦察"),
        (GameAction.pass, "跳过")
    ])
    func actionContextTitlesUseChineseBoardTerms(action: GameAction, title: String) {
        #expect(ActionContextBar.title(for: action) == title)
        #expect(ActionDisplay.title(for: action) == title)
    }

    @Test func actionContextInstructionNamesTheNextRequiredChoice() {
        let buildChoices: [GameCore.LegalChoice] = [
            .init(
                id: "build:birmingham:0",
                label: "伯明翰",
                value: .buildTarget(locationID: "birmingham", slotIndex: 0)
            )
        ]
        let routeChoices: [GameCore.LegalChoice] = [
            .init(id: "route:a-b", label: "A-B", value: .route(id: "a-b"))
        ]
        let developChoices: [GameCore.LegalChoice] = [
            .init(id: "tile:coal", label: "煤矿", value: .industryTile(id: "coal"))
        ]
        let merchantChoices: [GameCore.LegalChoice] = [
            .init(id: "merchant:oxford", label: "牛津", value: .merchant(id: "oxford"))
        ]
        let scoutChoices: [GameCore.LegalChoice] = [
            .init(id: "card:walsall", label: "Walsall", value: .card(id: "card-walsall"))
        ]
        let beerChoices: [GameCore.LegalChoice] = [
            .init(
                id: "source:beer:industry:beer-a",
                label: "德比 · 自己的啤酒厂",
                value: .resourceSource(.industry(placementID: "beer-a"))
            )
        ]

        #expect(ActionContextBar.instruction(for: .build, selectionLabels: [], choices: buildChoices) == "选择城市")
        #expect(ActionContextBar.instruction(for: .network, selectionLabels: ["伯明翰-沃尔索尔"], choices: routeChoices) == "已选 1 项，继续选择路线")
        #expect(ActionContextBar.instruction(for: .develop, selectionLabels: [], choices: developChoices) == "选择产业")
        #expect(ActionContextBar.instruction(for: .sell, selectionLabels: [], choices: merchantChoices) == "选择贸易商")
        #expect(ActionContextBar.instruction(for: .sell, selectionLabels: ["牛津"], choices: beerChoices) == "已选 1 项，选择啤酒来源")
        #expect(ActionContextBar.instruction(for: .loan, selectionLabels: [], choices: []) == "确认贷款")
        #expect(ActionContextBar.instruction(for: .scout, selectionLabels: ["Walsall"], choices: scoutChoices) == "已选 1 项，选择额外手牌")
        #expect(ActionContextBar.instruction(for: .pass, selectionLabels: [], choices: []) == "确认跳过")
    }

    @Test func actionContextProgressUsesPerTurnBudgetForFirstCanalRound() {
        let progress = ActionContextProgress(
            era: .canal,
            roundNumber: 1,
            actionsRemaining: 1
        )

        #expect(progress == ActionContextProgress(current: 1, total: 1))
    }

    @Test func actionContextProgressUsesPerTurnBudgetForLaterCanalRounds() {
        #expect(ActionContextProgress(
            era: .canal,
            roundNumber: 2,
            actionsRemaining: 2
        ) == ActionContextProgress(current: 1, total: 2))
        #expect(ActionContextProgress(
            era: .canal,
            roundNumber: 2,
            actionsRemaining: 1
        ) == ActionContextProgress(current: 2, total: 2))
    }

    @Test func actionContextProgressDoesNotUseGlobalActionNumber() {
        let progress = ActionContextProgress(
            era: .rail,
            roundNumber: 6,
            actionsRemaining: 1
        )

        #expect(progress == ActionContextProgress(current: 2, total: 2))
    }

    @Test(arguments: [
        (CGFloat(667), CGFloat(280.14)),
        (CGFloat(852), CGFloat(357.84)),
        (CGFloat(932), CGFloat(360)),
        (CGFloat(1_366), CGFloat(360))
    ])
    func phoneDrawerWidthUsesFortyTwoPercentCappedAtThreeSixty(
        viewportWidth: CGFloat,
        expected: CGFloat
    ) {
        #expect(MatchInteractionReducer.drawerWidth(viewportWidth: viewportWidth) == expected)
    }
}
