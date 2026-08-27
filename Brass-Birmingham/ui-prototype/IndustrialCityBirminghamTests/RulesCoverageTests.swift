import Foundation
import Testing

@testable import IndustrialCityBirmingham

struct RulesCoverageTests {
    private enum CoverageError: Error, Equatable {
        case invalidRiskIDs
        case invalidAreas
        case duplicateTestName
        case unmatchedTestName(String)
        case rulesRiskCountMismatch
        case areaProbeExecuted
    }

    private struct Manifest: Equatable {
        struct Risk: Equatable {
            let id: Int
            let testNames: [String]
        }

        let risks: [Risk]
        let areas: [String: [String]]
    }

    private struct ExecutableTest {
        let name: String
        let run: () throws -> Void
    }

    @Test func sectionTwelveRiskManifestMatchesExecutableNamedTestsAndRulesDocument() throws {
        let registry = executableRegistry()
        let manifest = canonicalManifest()

        try runManifest(manifest, registry: registry)
    }

    @Test func coverageManifestFailsClosedForAnUnmatchedTestName() throws {
        let valid = canonicalManifest()
        var risks = valid.risks
        risks[0] = .init(id: risks[0].id, testNames: ["missingRulesCoverageTest"])
        let malformed = Manifest(risks: risks, areas: valid.areas)

        #expect(throws: CoverageError.unmatchedTestName("missingRulesCoverageTest")) {
            try validate(malformed, registry: executableRegistry())
        }
    }

    @Test func coverageManifestExecutesAreaBehaviorClosures() throws {
        var registry = executableRegistry()
        let name = "identicalSeedsProduceIdenticalCanonicalStateAndReplay"
        registry[name] = .init(name: name, run: { throw CoverageError.areaProbeExecuted })

        #expect(throws: CoverageError.areaProbeExecuted) {
            try runManifest(canonicalManifest(), registry: registry)
        }
    }

    @Test func coverageManifestRejectsOrdinaryHelperThatIsNotATest() throws {
        let helperName = "ordinaryHelperMasqueradingAsTest"
        var registry = executableRegistry()
        registry[helperName] = .init(name: helperName, run: ordinaryHelperMasqueradingAsTest)
        let valid = canonicalManifest()
        var areas = valid.areas
        areas["setup"] = [helperName]

        #expect(throws: CoverageError.unmatchedTestName(helperName)) {
            try validate(.init(risks: valid.risks, areas: areas), registry: registry)
        }
    }

    @Test func coverageManifestRejectsDuplicateTestNamesAcrossRisksAndAreas() throws {
        let valid = canonicalManifest()
        var areas = valid.areas
        areas["setup", default: []].append(valid.risks[0].testNames[0])

        #expect(throws: CoverageError.duplicateTestName) {
            try validate(.init(risks: valid.risks, areas: areas), registry: executableRegistry())
        }
    }

    private func runManifest(_ manifest: Manifest, registry: [String: ExecutableTest]) throws {
        try validate(manifest, registry: registry)
        let areaOrder = ["setup", "resources", "actions", "turns", "scoring"]
        let requestedNames = manifest.risks.flatMap(\.testNames)
            + areaOrder.flatMap { manifest.areas[$0] ?? [] }
        var executed: Set<String> = []
        for name in requestedNames where executed.insert(name).inserted {
            try #require(registry[name]).run()
        }
    }

    private func validate(_ manifest: Manifest, registry: [String: ExecutableTest]) throws {
        guard manifest.risks.map(\.id) == Array(1...12) else {
            throw CoverageError.invalidRiskIDs
        }
        guard Set(manifest.areas.keys) == ["setup", "resources", "actions", "turns", "scoring"],
              manifest.areas.values.allSatisfy({ !$0.isEmpty })
        else { throw CoverageError.invalidAreas }

        let rules = try String(contentsOf: rulesURL(), encoding: .utf8)
        let section = try #require(rules.components(separatedBy: "## 12. 高风险易错规则").last?
            .components(separatedBy: "## 13.").first)
        let documentedRiskCount = section.split(separator: "\n").filter { line in
            line.range(of: #"^\d+\. "#, options: .regularExpression) != nil
        }.count
        guard documentedRiskCount == manifest.risks.count else {
            throw CoverageError.rulesRiskCountMismatch
        }

        let names = manifest.risks.flatMap(\.testNames) + manifest.areas.values.flatMap { $0 }
        guard Set(names).count == names.count else { throw CoverageError.duplicateTestName }
        let declarations = try declaredTestNames()
        for name in names {
            guard registry[name] != nil, declarations.contains(name) else {
                throw CoverageError.unmatchedTestName(name)
            }
        }
    }

    private func canonicalManifest() -> Manifest {
        Manifest(
            risks: [
                .init(id: 1, testNames: ["rulesTwelveSeparatesCardsPlayerNetworkPlayerCountAndResourceConnectivity"]),
                .init(id: 2, testNames: ["playerCountMasksExcludeLocationsAndRoutesFromNetworkQueries"]),
                .init(id: 3, testNames: ["linkOnlyNetworkExtendsOnlyFromOwnLinkAndIgnoresOpponentLink"]),
                .init(id: 4, testNames: ["coalReturnsOnlyNearestConnectedTierWithStableTieChoices"]),
                .init(id: 5, testNames: ["beerAllowsOwnAnywhereOpponentConnectedAndOnlySelectedMerchantWhenSelling"]),
                .init(id: 6, testNames: ["multiSellResolvesProgressivelyAndTwoBeerSaleRejectsTwoMerchantBeersAtomically"]),
                .init(id: 7, testNames: ["opponentCoalOverbuildRequiresGlobalAndMarketExhaustionThenPreservesOldOwnerScore"]),
                .init(id: 8, testNames: ["doubleRailConsumesCoalInOrderLetsFirstLinkUnlockSecondAndUsesOwnBeerAnywhere"]),
                .init(id: 9, testNames: ["canalPreparationPreservesMarketsRefillsMerchantsRedealsAndPreservesLongLivedState"]),
                .init(id: 10, testNames: ["finalRailScoringRepeatsPreservedLevelTwoAwardsNoIncomeAndResolvesAllWinnerTies"]),
                .init(id: 11, testNames: ["sellUsesConcreteConnectedMerchantConsumesAtMostOneMerchantBeerAndAppliesRewards"]),
                .init(id: 12, testNames: [
                    "sellRejectsBlankWrongTypeDisconnectedFlippedAndSecondInvalidSaleWithoutMutation",
                    "coalMarketRequiresEdgeConnectionUsesCheapestFilledSlotThenUnlimitedEight",
                ]),
            ],
            areas: [
                "setup": ["identicalSeedsProduceIdenticalCanonicalStateAndReplay"],
                "resources": ["sequentialPlansRecomputeAcrossSameMineAndMapToMarketWhilePreservingComponents"],
                "actions": [
                    "locationCardBuildCommitsOneEventOneVersionAndOneAction",
                    "canalNetworkRejectsDisconnectedAtomicallyThenPlacesOneLinkForThreePounds",
                    "developValidatesAndResolvesTwoLowestTilesInOrderWithIronPriority",
                    "sellAppliesEveryCatalogMerchantRewardOnlyWhenMerchantBeerIsUsed",
                    "loanMovesDownThreeIncomeLevelsAndHonorsMinusTenFloor",
                    "scoutDiscardsThreeDistinctNormalCardsTakesBothWildsAndRejectsWhenWildHeld",
                    "catalogAwarePassReturnsWildCardToPoolAndReplaysExactly",
                ],
                "turns": [
                    "firstCanalRoundGivesEachSeatOneActionThenTwoAndRefillsToEight",
                    "forcedSaleSubmittedThroughHostIncrementsVersionAndReplaysExactly",
                ],
                "scoring": ["eraScoringCountsEveryHyperedgeAdjacentFlippedIndustryAndRemovesOnlyEraLinks"],
            ]
        )
    }

    private func executableRegistry() -> [String: ExecutableTest] {
        let tests = [
            ExecutableTest(name: "rulesTwelveSeparatesCardsPlayerNetworkPlayerCountAndResourceConnectivity", run: BuildAndNetworkRulesTests().rulesTwelveSeparatesCardsPlayerNetworkPlayerCountAndResourceConnectivity),
            ExecutableTest(name: "playerCountMasksExcludeLocationsAndRoutesFromNetworkQueries", run: TopologyRulesTests().playerCountMasksExcludeLocationsAndRoutesFromNetworkQueries),
            ExecutableTest(name: "linkOnlyNetworkExtendsOnlyFromOwnLinkAndIgnoresOpponentLink", run: TopologyRulesTests().linkOnlyNetworkExtendsOnlyFromOwnLinkAndIgnoresOpponentLink),
            ExecutableTest(name: "coalReturnsOnlyNearestConnectedTierWithStableTieChoices", run: ResourceRulesTests().coalReturnsOnlyNearestConnectedTierWithStableTieChoices),
            ExecutableTest(name: "beerAllowsOwnAnywhereOpponentConnectedAndOnlySelectedMerchantWhenSelling", run: ResourceRulesTests().beerAllowsOwnAnywhereOpponentConnectedAndOnlySelectedMerchantWhenSelling),
            ExecutableTest(name: "multiSellResolvesProgressivelyAndTwoBeerSaleRejectsTwoMerchantBeersAtomically", run: DevelopSellSimpleActionTests().multiSellResolvesProgressivelyAndTwoBeerSaleRejectsTwoMerchantBeersAtomically),
            ExecutableTest(name: "opponentCoalOverbuildRequiresGlobalAndMarketExhaustionThenPreservesOldOwnerScore", run: BuildAndNetworkRulesTests().opponentCoalOverbuildRequiresGlobalAndMarketExhaustionThenPreservesOldOwnerScore),
            ExecutableTest(name: "doubleRailConsumesCoalInOrderLetsFirstLinkUnlockSecondAndUsesOwnBeerAnywhere", run: BuildAndNetworkRulesTests().doubleRailConsumesCoalInOrderLetsFirstLinkUnlockSecondAndUsesOwnBeerAnywhere),
            ExecutableTest(name: "canalPreparationPreservesMarketsRefillsMerchantsRedealsAndPreservesLongLivedState", run: TurnScoringRulesTests().canalPreparationPreservesMarketsRefillsMerchantsRedealsAndPreservesLongLivedState),
            ExecutableTest(name: "finalRailScoringRepeatsPreservedLevelTwoAwardsNoIncomeAndResolvesAllWinnerTies", run: TurnScoringRulesTests().finalRailScoringRepeatsPreservedLevelTwoAwardsNoIncomeAndResolvesAllWinnerTies),
            ExecutableTest(name: "sellUsesConcreteConnectedMerchantConsumesAtMostOneMerchantBeerAndAppliesRewards", run: DevelopSellSimpleActionTests().sellUsesConcreteConnectedMerchantConsumesAtMostOneMerchantBeerAndAppliesRewards),
            ExecutableTest(name: "sellRejectsBlankWrongTypeDisconnectedFlippedAndSecondInvalidSaleWithoutMutation", run: DevelopSellSimpleActionTests().sellRejectsBlankWrongTypeDisconnectedFlippedAndSecondInvalidSaleWithoutMutation),
            ExecutableTest(name: "coalMarketRequiresEdgeConnectionUsesCheapestFilledSlotThenUnlimitedEight", run: ResourceRulesTests().coalMarketRequiresEdgeConnectionUsesCheapestFilledSlotThenUnlimitedEight),
            ExecutableTest(name: "identicalSeedsProduceIdenticalCanonicalStateAndReplay", run: GameSetupTests().identicalSeedsProduceIdenticalCanonicalStateAndReplay),
            ExecutableTest(name: "sequentialPlansRecomputeAcrossSameMineAndMapToMarketWhilePreservingComponents", run: ResourceRulesTests().sequentialPlansRecomputeAcrossSameMineAndMapToMarketWhilePreservingComponents),
            ExecutableTest(name: "locationCardBuildCommitsOneEventOneVersionAndOneAction", run: BuildAndNetworkRulesTests().locationCardBuildCommitsOneEventOneVersionAndOneAction),
            ExecutableTest(name: "canalNetworkRejectsDisconnectedAtomicallyThenPlacesOneLinkForThreePounds", run: BuildAndNetworkRulesTests().canalNetworkRejectsDisconnectedAtomicallyThenPlacesOneLinkForThreePounds),
            ExecutableTest(name: "developValidatesAndResolvesTwoLowestTilesInOrderWithIronPriority", run: DevelopSellSimpleActionTests().developValidatesAndResolvesTwoLowestTilesInOrderWithIronPriority),
            ExecutableTest(name: "sellAppliesEveryCatalogMerchantRewardOnlyWhenMerchantBeerIsUsed", run: DevelopSellSimpleActionTests().sellAppliesEveryCatalogMerchantRewardOnlyWhenMerchantBeerIsUsed),
            ExecutableTest(name: "loanMovesDownThreeIncomeLevelsAndHonorsMinusTenFloor", run: DevelopSellSimpleActionTests().loanMovesDownThreeIncomeLevelsAndHonorsMinusTenFloor),
            ExecutableTest(name: "scoutDiscardsThreeDistinctNormalCardsTakesBothWildsAndRejectsWhenWildHeld", run: DevelopSellSimpleActionTests().scoutDiscardsThreeDistinctNormalCardsTakesBothWildsAndRejectsWhenWildHeld),
            ExecutableTest(name: "catalogAwarePassReturnsWildCardToPoolAndReplaysExactly", run: DevelopSellSimpleActionTests().catalogAwarePassReturnsWildCardToPoolAndReplaysExactly),
            ExecutableTest(name: "firstCanalRoundGivesEachSeatOneActionThenTwoAndRefillsToEight", run: { try TurnScoringRulesTests().firstCanalRoundGivesEachSeatOneActionThenTwoAndRefillsToEight(playerCount: 2) }),
            ExecutableTest(name: "forcedSaleSubmittedThroughHostIncrementsVersionAndReplaysExactly", run: GameRulesEngineTests().forcedSaleSubmittedThroughHostIncrementsVersionAndReplaysExactly),
            ExecutableTest(name: "eraScoringCountsEveryHyperedgeAdjacentFlippedIndustryAndRemovesOnlyEraLinks", run: TurnScoringRulesTests().eraScoringCountsEveryHyperedgeAdjacentFlippedIndustryAndRemovesOnlyEraLinks),
        ]
        return Dictionary(uniqueKeysWithValues: tests.map { ($0.name, $0) })
    }

    private func rulesURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "RULES.md")
    }

    private func ordinaryHelperMasqueradingAsTest() throws {}

    private func declaredTestNames() throws -> Set<String> {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let expression = try NSRegularExpression(pattern: #"\bfunc\s+([A-Za-z][A-Za-z0-9_]*)\s*\("#)
        var names: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            var awaitingTestDeclaration = false
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                if text.trimmingCharacters(in: .whitespaces).hasPrefix("@Test") {
                    awaitingTestDeclaration = true
                }
                guard awaitingTestDeclaration else { continue }
                let range = NSRange(text.startIndex..., in: text)
                guard let match = expression.firstMatch(in: text, range: range),
                      let swiftRange = Range(match.range(at: 1), in: text)
                else { continue }
                names.insert(String(text[swiftRange]))
                awaitingTestDeclaration = false
            }
        }
        return names
    }
}
