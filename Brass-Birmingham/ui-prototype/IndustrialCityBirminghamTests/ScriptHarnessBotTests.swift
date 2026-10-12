import Foundation
import Testing

@testable import IndustrialCityBirmingham

#if DEBUG
/// 双模拟器自动对局的机器人决策:种子确定性、pass 兜底、合法选择采样范围。
struct ScriptHarnessBotTests {
    private func passOption(cardID: String) -> GameCore.ActionOption {
        .init(
            id: "pass:\(cardID)",
            action: .pass,
            cardIDs: [cardID],
            targetIDs: [],
            payload: .pass(.init(cardID: cardID)),
            confirmation: .init(cashDelta: 0, incomeDelta: 0, victoryPointDelta: 0)
        )
    }

    private func loanOption(cardID: String) -> GameCore.ActionOption {
        .init(
            id: "loan:\(cardID)",
            action: .loan,
            cardIDs: [cardID],
            targetIDs: [],
            payload: .loan(.init(cardID: cardID)),
            confirmation: .init(cashDelta: 30, incomeDelta: -3, victoryPointDelta: 0)
        )
    }

    private func choice(id: String) -> GameCore.LegalChoice {
        .init(id: id, label: id, value: .industryPlacement(id: id))
    }

    // MARK: 动作挑选

    @Test func pickActionSkipsPassAndForcedSale() {
        var bot = ScriptHarnessBot(seed: 7)
        let byCardID: [String: [GameCore.ActionKind]] = [
            "c1": [.pass, .loan],
            "c2": [.forcedSale],
        ]
        for _ in 0..<32 {
            let pick = bot.pickAction(byCardID: byCardID)
            #expect(pick?.action == .loan)
            #expect(pick?.cardID == "c1")
        }
    }

    @Test func pickActionReturnsNilWhenOnlyPassAvailable() {
        var bot = ScriptHarnessBot(seed: 7)
        let byCardID: [String: [GameCore.ActionKind]] = ["c1": [.pass], "c2": []]
        #expect(bot.pickAction(byCardID: byCardID) == nil)
        #expect(bot.pickAction(byCardID: [:]) == nil)
    }

    @Test func pickActionCoversEveryCandidateUnderVaryingSeeds() {
        // 大量组合 + 多个种子下,每个候选都应有机会被选中(覆盖面)。
        let kinds: [GameCore.ActionKind] = [.build, .network, .develop, .sell, .loan, .scout]
        let byCardID = Dictionary(uniqueKeysWithValues: (0..<6).map { index in
            ("card\(index)", Array(kinds[index...]) + [.pass])
        })
        var seen = Set<String>()
        for seed in UInt64(1)...64 {
            var bot = ScriptHarnessBot(seed: seed)
            if let pick = bot.pickAction(byCardID: byCardID) {
                seen.insert("\(pick.cardID):\(pick.action.rawValue)")
            }
        }
        #expect(seen.count >= 12)
    }

    // MARK: 种子确定性

    @Test func sameSeedReplaysSameDecisionSequence() {
        let byCardID: [String: [GameCore.ActionKind]] = [
            "c1": [.build, .sell], "c2": [.network, .loan], "c3": [.develop],
        ]
        var a = ScriptHarnessBot(seed: 20261011)
        var b = ScriptHarnessBot(seed: 20261011)
        for _ in 0..<24 {
            #expect(a.pickAction(byCardID: byCardID) == b.pickAction(byCardID: byCardID))
        }
    }

    @Test func differentSeedsUsuallyDiverge() {
        let byCardID: [String: [GameCore.ActionKind]] = [
            "c1": [.build, .sell], "c2": [.network, .loan], "c3": [.develop, .scout],
        ]
        var a = ScriptHarnessBot(seed: 1)
        var b = ScriptHarnessBot(seed: 2)
        var differences = 0
        for _ in 0..<24 {
            if a.pickAction(byCardID: byCardID) != b.pickAction(byCardID: byCardID) {
                differences += 1
            }
        }
        #expect(differences >= 8)
    }

    // MARK: pass 兜底

    @Test func pickPassCardChoosesOnlyFromPassOptions() {
        var bot = ScriptHarnessBot(seed: 9)
        let options = [
            passOption(cardID: "c1"), loanOption(cardID: "c2"), passOption(cardID: "c3"),
        ]
        var seen = Set<String>()
        for _ in 0..<32 {
            seen.insert(bot.pickPassCard(options) ?? "<nil>")
        }
        #expect(seen.isDisjoint(with: ["c2", "<nil>"]))
        #expect(seen.contains("c1") && seen.contains("c3"))
    }

    @Test func pickPassCardReturnsNilWithoutPassOptions() {
        var bot = ScriptHarnessBot(seed: 9)
        #expect(bot.pickPassCard([loanOption(cardID: "c1")]) == nil)
        #expect(bot.pickPassCard([]) == nil)
    }

    // MARK: 多步流选择

    @Test func pickChoiceStaysWithinChoices() {
        var bot = ScriptHarnessBot(seed: 4)
        let choices = (0..<5).map { choice(id: "ch\($0)") }
        var seen = Set<String>()
        for _ in 0..<32 {
            guard let picked = bot.pickChoice(choices) else {
                Issue.record("非空选择列表不应返回 nil")
                return
            }
            #expect(choices.contains(picked))
            seen.insert(picked.id)
        }
        #expect(seen.count >= 3)
    }

    @Test func pickChoiceReturnsNilOnEmptyChoices() {
        var bot = ScriptHarnessBot(seed: 4)
        #expect(bot.pickChoice([]) == nil)
    }

    // MARK: 种子解析

    @Test func seedParsesFromLaunchArguments() {
        #expect(ScriptHarnessBot.seed(from: ["-local-harness-seed", "12345"]) == 12345)
        #expect(ScriptHarnessBot.seed(from: ["-local-harness-seed"]) == nil)
        #expect(ScriptHarnessBot.seed(from: ["-local-harness-seed", "abc"]) == nil)
        #expect(ScriptHarnessBot.seed(from: []) == nil)
        #expect(
            ScriptHarnessBot.seed(from: ["-local-harness-seed", "\(UInt64.max)"]) == UInt64.max
        )
    }

    @Test func defaultSeedIsStablePerRoom() {
        let a = ScriptHarnessBot.defaultSeed(roomID: "AUTO42")
        #expect(a == ScriptHarnessBot.defaultSeed(roomID: "AUTO42"))
        #expect(a != ScriptHarnessBot.defaultSeed(roomID: "AUTO43"))
        #expect(a != 0)
    }

    @Test func splitMix64IsDeterministicAndDistinctPerSeed() {
        var a = SplitMix64(seed: 100)
        var b = SplitMix64(seed: 100)
        var c = SplitMix64(seed: 101)
        var aValues: [UInt64] = []
        var cValues: [UInt64] = []
        for _ in 0..<8 {
            let value = a.next()
            #expect(value == b.next())
            aValues.append(value)
            cValues.append(c.next())
        }
        #expect(Set(aValues).count == 8)
        #expect(aValues != cValues)
    }
}
#endif
