import SwiftUI
import PokerEngine

struct MenuView: View {
    let onStart: (GameConfig, UInt64, AIDifficulty) -> Void
    @State private var isSNG = false
    @State private var playerCount = 6
    @State private var cashSB = 10
    @State private var cashStack = 2000
    @State private var buyIn = 1000
    @State private var difficulty: AIDifficulty = .baseline

    /// SNG 奖金表随人数收敛：2 人只发前 2 名（70/30），3 人及以上发前 3 名（50/30/20）。
    /// 奖金档数不得超过参赛人数，否则引擎终局结算时第 3 名无人认领（引擎会跳过该档，但配置本身就该正确）。
    private var sngPayouts: [Double] {
        playerCount == 2 ? [0.7, 0.3] : [0.5, 0.3, 0.2]
    }

    private var config: GameConfig {
        let format: GameFormat = isSNG
            ? .sng(SNGConfig(buyIn: buyIn, startingStack: 1500,
                             levels: [BlindLevel(sb: 10, bb: 20, hands: 12),
                                      BlindLevel(sb: 25, bb: 50, hands: 12),
                                      BlindLevel(sb: 50, bb: 100, hands: 12),
                                      BlindLevel(sb: 100, bb: 200, hands: 12)],
                             payouts: sngPayouts))
            : .cash(sb: cashSB, bb: cashSB * 2)
        return GameConfig(playerCount: playerCount,
                          startingStack: isSNG ? 1500 : cashStack,
                          format: format)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("模式", selection: $isSNG) {
                    Text("现金局").tag(false)
                    Text("单桌锦标赛 SNG").tag(true)
                }
                Picker("AI 难度", selection: $difficulty) {
                    ForEach(AIDifficulty.allCases) { Text($0.rawValue).tag($0) }
                }
                Stepper("玩家人数：\(playerCount)", value: $playerCount, in: 2...9)
                if isSNG {
                    Stepper("买入：\(buyIn)", value: $buyIn, in: 100...10000, step: 100)
                } else {
                    Stepper("小盲：\(cashSB)", value: $cashSB, in: 1...1000, step: 5)
                    Stepper("初始筹码：\(cashStack)", value: $cashStack, in: 500...100000, step: 500)
                }
                Button("开始游戏") {
                    onStart(config, UInt64(Date().timeIntervalSince1970 * 1000), difficulty)
                }
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("德州扑克")
        }
    }
}
