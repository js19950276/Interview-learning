import Testing
@testable import IndustrialCityBirmingham

@MainActor
struct ActionFlowTests {
    @Test func eachActionStartsWithItsEmptyFixtureState() {
        #expect(ActionFlowState.start(.build) == .build(BuildDraft()))
        #expect(ActionFlowState.start(.network) == .network(NetworkDraft()))
        #expect(ActionFlowState.start(.develop) == .develop(DevelopDraft()))
        #expect(ActionFlowState.start(.sell) == .sell(SellDraft()))
        #expect(ActionFlowState.start(.loan) == .loan)
        #expect(ActionFlowState.start(.scout) == .scout(ScoutDraft()))
        #expect(ActionFlowState.start(.pass) == .pass)
    }

    @Test func emptySelectionFlowsAreNotConfirmable() {
        let flows: [ActionFlowState] = [
            .idle,
            .build(BuildDraft()),
            .network(NetworkDraft()),
            .develop(DevelopDraft()),
            .sell(SellDraft()),
            .scout(ScoutDraft())
        ]

        for flow in flows {
            #expect(flow.isConfirmable == false)
        }
    }

    @Test func loanAndPassAreImmediatelyConfirmable() {
        #expect(ActionFlowState.loan.isConfirmable)
        #expect(ActionFlowState.pass.isConfirmable)
    }

    @Test func selectionCountsDriveConfirmation() {
        #expect(ActionFlowState.build(BuildDraft(locationID: "birmingham")).isConfirmable)
        #expect(ActionFlowState.network(NetworkDraft(count: .one, routeIDs: ["route-1"])).isConfirmable)
        #expect(ActionFlowState.network(NetworkDraft(count: .two, routeIDs: ["route-1"])).isConfirmable == false)
        #expect(ActionFlowState.network(NetworkDraft(count: .two, routeIDs: ["route-1", "route-2"])).isConfirmable)
        #expect(ActionFlowState.develop(DevelopDraft(industryIDs: ["coal"])).isConfirmable)
        #expect(ActionFlowState.develop(DevelopDraft(industryIDs: ["coal", "iron"])).isConfirmable)
        #expect(ActionFlowState.develop(DevelopDraft(industryIDs: ["coal", "iron", "beer"])).isConfirmable == false)
        #expect(ActionFlowState.sell(SellDraft(optionIDs: ["sell-1"])).isConfirmable)
        #expect(ActionFlowState.scout(ScoutDraft(extraCardIDs: ["card-1"])).isConfirmable == false)
        #expect(ActionFlowState.scout(ScoutDraft(extraCardIDs: ["card-1", "card-2"])).isConfirmable)
    }

    @Test func onlyBuildNetworkAndSellUseMapTargets() {
        #expect(ActionFlowState.build(BuildDraft()).usesMapTargets)
        #expect(ActionFlowState.network(NetworkDraft()).usesMapTargets)
        #expect(ActionFlowState.sell(SellDraft()).usesMapTargets)

        let nonMapFlows: [ActionFlowState] = [
            .idle,
            .develop(DevelopDraft()),
            .loan,
            .scout(ScoutDraft()),
            .pass
        ]
        for flow in nonMapFlows {
            #expect(flow.usesMapTargets == false)
        }
    }

    @Test(arguments: GameAction.allCases)
    func selectingANewCardResetsEveryActionDraft(_ action: GameAction) {
        let reducer = MatchInteractionReducer()
        reducer.selectCard("card-birmingham")
        reducer.selectAction(action)

        reducer.selectCard("card-coventry")

        #expect(reducer.selectedCardID == "card-coventry")
        #expect(reducer.selectedAction == nil)
        #expect(reducer.flow == .idle)
    }

    @Test func confirmOnlyFinishesAConfirmableFlowAndKeepsTheSelectedCard() {
        let reducer = MatchInteractionReducer()
        reducer.selectCard("card-birmingham")
        reducer.selectAction(.build)

        reducer.confirmFlow()

        #expect(reducer.selectedAction == .build)
        #expect(reducer.flow == .build(BuildDraft()))

        reducer.selectAction(.loan)
        reducer.confirmFlow()

        #expect(reducer.selectedCardID == "card-birmingham")
        #expect(reducer.selectedAction == nil)
        #expect(reducer.flow == .idle)
    }

    @Test func buildAcceptsOnlyFixtureLocationsAndBecomesConfirmable() {
        let reducer = MatchInteractionReducer()
        reducer.selectCard("card-birmingham")
        reducer.selectAction(.build)

        reducer.selectBuildLocation("not-in-fixture", fixture: .standard)
        #expect(reducer.flow == .build(BuildDraft()))
        #expect(reducer.flow.isConfirmable == false)

        reducer.selectBuildLocation("birmingham", fixture: .standard)
        #expect(reducer.flow == .build(BuildDraft(locationID: "birmingham")))
        #expect(reducer.flow.isConfirmable)
    }

    @Test func oneRouteNetworkAcceptsExactlyOneLegalRoute() {
        let reducer = MatchInteractionReducer()
        let routes = DemoFixture.match(playerCount: 4).routes
        reducer.selectAction(.network)

        reducer.appendNetworkRoute("birmingham-coventry", fixture: .standard, routes: routes)
        reducer.appendNetworkRoute("birmingham-walsall", fixture: .standard, routes: routes)

        #expect(
            reducer.flow == .network(
                NetworkDraft(count: .one, routeIDs: ["birmingham-coventry"])
            )
        )
        #expect(reducer.flow.isConfirmable)
    }

    @Test func twoRouteNetworkPreservesOrderAndRejectsInvalidDuplicateOrOverflowRoutes() {
        let reducer = MatchInteractionReducer()
        let routes = DemoFixture.match(playerCount: 4).routes
        reducer.selectAction(.network)
        reducer.setNetworkCount(.two)

        reducer.appendNetworkRoute("not-in-fixture", fixture: .standard, routes: routes)
        #expect(reducer.flow == .network(NetworkDraft(count: .two)))

        reducer.appendNetworkRoute("birmingham-walsall", fixture: .standard, routes: routes)
        reducer.appendNetworkRoute("birmingham-walsall", fixture: .standard, routes: routes)
        reducer.appendNetworkRoute("walsall-cannock", fixture: .standard, routes: routes)
        reducer.appendNetworkRoute("birmingham-coventry", fixture: .standard, routes: routes)

        #expect(
            reducer.flow == .network(
                NetworkDraft(
                    count: .two,
                    routeIDs: ["birmingham-walsall", "walsall-cannock"]
                )
            )
        )
        #expect(reducer.flow.isConfirmable)
    }

    @Test func changingNetworkCountClearsSelectedRoutes() {
        let reducer = MatchInteractionReducer()
        let routes = DemoFixture.match(playerCount: 4).routes
        reducer.selectAction(.network)
        reducer.appendNetworkRoute("birmingham-coventry", fixture: .standard, routes: routes)

        reducer.setNetworkCount(.two)

        #expect(reducer.flow == .network(NetworkDraft(count: .two)))
        #expect(reducer.flow.isConfirmable == false)
    }

    @Test func buildAndNetworkHighlightsFollowTheActiveDraft() {
        let reducer = MatchInteractionReducer()
        let match = DemoFixture.match(playerCount: 4)

        reducer.selectAction(.build)
        #expect(
            reducer.highlightedTargetIDs(fixture: .standard, routes: match.routes)
                == Set(ActionFixture.standard.buildLocationIDs)
        )

        reducer.selectAction(.network)
        reducer.setNetworkCount(.two)
        #expect(
            reducer.highlightedTargetIDs(fixture: .standard, routes: match.routes)
                == Set(ActionFixture.standard.networkRouteIDs)
        )

        reducer.appendNetworkRoute("birmingham-walsall", fixture: .standard, routes: match.routes)
        #expect(
            reducer.highlightedTargetIDs(fixture: .standard, routes: match.routes)
                == Set(["birmingham-coventry", "walsall-cannock"])
        )

        reducer.appendNetworkRoute("walsall-cannock", fixture: .standard, routes: match.routes)
        #expect(reducer.highlightedTargetIDs(fixture: .standard, routes: match.routes).isEmpty)
    }

    @Test func twoRouteNetworkRejectsASecondRouteDisconnectedFromTheFirst() {
        let reducer = MatchInteractionReducer()
        let routes = DemoFixture.match(playerCount: 4).routes
        reducer.selectAction(.network)
        reducer.setNetworkCount(.two)

        reducer.appendNetworkRoute("birmingham-coventry", fixture: .standard, routes: routes)
        reducer.appendNetworkRoute("walsall-cannock", fixture: .standard, routes: routes)

        #expect(
            reducer.flow == .network(
                NetworkDraft(count: .two, routeIDs: ["birmingham-coventry"])
            )
        )
        #expect(reducer.flow.isConfirmable == false)
    }

    @Test func networkActionCostsAreEraAwareAndDriveConfirmationDeltas() {
        let cases: [(isRailEra: Bool, count: NetworkCount, money: Int, coal: Int, beer: Int)] = [
            (false, .one, 3, 0, 0),
            (true, .one, 5, 1, 0),
            (true, .two, 15, 2, 1)
        ]

        for item in cases {
            let cost = NetworkActionCost(isRailEra: item.isRailEra, count: item.count)
            #expect(cost.money == item.money)
            #expect(cost.coal == item.coal)
            #expect(cost.beer == item.beer)

            let summary = ActionConfirmationSummary.fixture(
                cardTitle: "Birmingham",
                action: .network,
                networkCost: cost
            )
            #expect(summary.moneyDelta == -cost.money)
            #expect(summary.coalDelta == -cost.coal)
            #expect(summary.beerDelta == -cost.beer)
        }
    }

    @Test func developAcceptsOnlyFixtureIndustriesAndTogglesASelectionOff() {
        let reducer = MatchInteractionReducer()
        reducer.selectAction(.develop)

        reducer.toggleDevelopIndustry("not-in-fixture", fixture: .standard)
        #expect(reducer.flow == .develop(DevelopDraft()))

        reducer.toggleDevelopIndustry("industry-coal", fixture: .standard)
        #expect(reducer.flow == .develop(DevelopDraft(industryIDs: ["industry-coal"])))
        #expect(reducer.flow.isConfirmable)

        reducer.toggleDevelopIndustry("industry-coal", fixture: .standard)
        #expect(reducer.flow == .develop(DevelopDraft()))
        #expect(reducer.flow.isConfirmable == false)
    }

    @Test func developPreservesOrderCapsSelectionAtTwoAndConsumesOneIronEach() {
        let reducer = MatchInteractionReducer()
        let threeIndustryFixture = ActionFixture(
            availableActions: ActionFixture.standard.availableActions,
            buildLocationIDs: ActionFixture.standard.buildLocationIDs,
            networkRouteIDs: ActionFixture.standard.networkRouteIDs,
            developIndustryIDs: ["industry-iron", "industry-coal", "industry-brewery"],
            sellOptions: ActionFixture.standard.sellOptions,
            scoutCardIDs: ActionFixture.standard.scoutCardIDs
        )
        reducer.selectAction(.develop)

        reducer.toggleDevelopIndustry("industry-iron", fixture: threeIndustryFixture)

        let oneIndustrySummary = ActionConfirmationSummary.fixture(
            cardTitle: "Birmingham",
            action: .develop,
            developIndustryCount: 1
        )
        #expect(oneIndustrySummary.ironDelta == -1)

        reducer.toggleDevelopIndustry("industry-coal", fixture: threeIndustryFixture)
        reducer.toggleDevelopIndustry("industry-brewery", fixture: threeIndustryFixture)

        #expect(
            reducer.flow == .develop(
                DevelopDraft(industryIDs: ["industry-iron", "industry-coal"])
            )
        )
        #expect(reducer.flow.isConfirmable)

        let summary = ActionConfirmationSummary.fixture(
            cardTitle: "Birmingham",
            action: .develop,
            developIndustryCount: 2
        )
        #expect(summary.ironDelta == -2)
    }

    @Test func sellAcceptsOnlyFixtureOptionsAndPreservesInsertionOrder() {
        let reducer = MatchInteractionReducer()
        reducer.selectAction(.sell)

        reducer.toggleSaleOption("not-in-fixture", fixture: .standard)
        #expect(reducer.flow == .sell(SellDraft()))

        reducer.toggleSaleOption("sell-manufacturer-warrington", fixture: .standard)
        reducer.toggleSaleOption("sell-cotton-oxford", fixture: .standard)

        #expect(
            reducer.flow == .sell(
                SellDraft(optionIDs: [
                    "sell-manufacturer-warrington",
                    "sell-cotton-oxford"
                ])
            )
        )
        #expect(reducer.flow.isConfirmable)
    }

    @Test func sellTappingAnAddedOptionRemovesItAndOneOptionRemainsConfirmable() {
        let reducer = MatchInteractionReducer()
        reducer.selectAction(.sell)

        reducer.toggleSaleOption("sell-cotton-oxford", fixture: .standard)
        reducer.toggleSaleOption("sell-manufacturer-warrington", fixture: .standard)
        reducer.toggleSaleOption("sell-cotton-oxford", fixture: .standard)

        #expect(
            reducer.flow == .sell(
                SellDraft(optionIDs: ["sell-manufacturer-warrington"])
            )
        )
        #expect(reducer.flow.isConfirmable)
    }

    @Test func sellIndustrySelectionIsFixtureValidatedAndOpensItsMerchantOptions() {
        let reducer = MatchInteractionReducer()
        reducer.selectAction(.sell)

        reducer.selectSaleIndustry("industry-iron", fixture: .standard)
        #expect(reducer.flow == .sell(SellDraft()))

        reducer.selectSaleIndustry("industry-cotton", fixture: .standard)
        #expect(
            reducer.flow == .sell(
                SellDraft(focusedIndustryID: "industry-cotton")
            )
        )
    }

    @Test func selectedSaleFixtureValuesDriveMerchantRewardAndIncome() {
        let selectedOptions = ActionFixture.standard.sellOptions.filter {
            ["sell-cotton-oxford", "sell-manufacturer-warrington"].contains($0.id)
        }

        let summary = ActionConfirmationSummary.fixture(
            cardTitle: "Birmingham",
            action: .sell,
            sellOptions: selectedOptions
        )

        #expect(summary.moneyDelta == 14)
        #expect(summary.beerDelta == -2)
        #expect(summary.incomeBefore == 5)
        #expect(summary.incomeAfter == 7)
    }

    @Test func loanPreviewReportsMoneyAndThreeIncomeLevelsDown() {
        let summary = ActionConfirmationSummary.fixture(
            cardTitle: "Birmingham",
            action: .loan
        )

        #expect(summary.moneyDelta == 30)
        #expect(summary.moneyBefore == 17)
        #expect(summary.moneyAfter == 47)
        #expect(summary.incomeBefore == 5)
        #expect(summary.incomeAfter == 2)
    }

    @Test func scoutTogglesTwoDistinctFixtureCardsAndRejectsTheActionCardInvalidAndOverflow() {
        let reducer = MatchInteractionReducer()
        let fixture = ActionFixture(
            availableActions: ActionFixture.standard.availableActions,
            buildLocationIDs: ActionFixture.standard.buildLocationIDs,
            networkRouteIDs: ActionFixture.standard.networkRouteIDs,
            developIndustryIDs: ActionFixture.standard.developIndustryIDs,
            sellOptions: ActionFixture.standard.sellOptions,
            scoutCardIDs: ["card-birmingham", "card-walsall", "card-iron", "card-coal"]
        )
        reducer.selectCard("card-birmingham")
        reducer.selectAction(.scout)

        reducer.toggleScoutCard("card-birmingham", fixture: fixture)
        reducer.toggleScoutCard("not-in-fixture", fixture: fixture)
        #expect(reducer.flow == .scout(ScoutDraft()))

        reducer.toggleScoutCard("card-walsall", fixture: fixture)
        reducer.toggleScoutCard("card-iron", fixture: fixture)
        reducer.toggleScoutCard("card-coal", fixture: fixture)
        #expect(
            reducer.flow == .scout(
                ScoutDraft(extraCardIDs: ["card-walsall", "card-iron"])
            )
        )
        #expect(reducer.flow.isConfirmable)

        reducer.toggleScoutCard("card-walsall", fixture: fixture)
        #expect(reducer.flow == .scout(ScoutDraft(extraCardIDs: ["card-iron"])))
        #expect(reducer.flow.isConfirmable == false)
    }

    @Test func passPreviewLabelsDeriveFromSummaryCounts() {
        let summary = ActionConfirmationSummary(
            discardedCard: "Birmingham",
            moneyDelta: 0,
            coalDelta: 0,
            ironDelta: 0,
            beerDelta: 0,
            incomeBefore: nil,
            incomeAfter: nil,
            discardedCardCount: 3,
            actionAdvance: 2
        )

        let previews = ConfirmationPreviewItem.pass(summary: summary, actionNumber: 4)

        #expect(previews.map(\.title) == [
            "弃掉 3 张所选卡牌",
            "行动计数从 4 变为 6"
        ])
    }

    @Test func passPreviewDiscardsOneCardAndAdvancesOneActionWithoutMapTargets() {
        let summary = ActionConfirmationSummary.fixture(
            cardTitle: "Birmingham",
            action: .pass
        )

        #expect(summary.discardedCard == "Birmingham")
        #expect(summary.discardedCardCount == 1)
        #expect(summary.actionAdvance == 1)

        let reducer = MatchInteractionReducer()
        let match = DemoFixture.match(playerCount: 4)
        for action in [GameAction.loan, .scout, .pass] {
            reducer.selectAction(action)
            #expect(
                reducer.highlightedTargetIDs(fixture: .standard, routes: match.routes).isEmpty
            )
        }
    }
}
