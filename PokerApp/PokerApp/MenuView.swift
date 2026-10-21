import SwiftUI
import PokerEngine

struct MenuView: View {
    let onStart: (GameConfig, UInt64) -> Void
    @State private var isSNG = false
    @State private var playerCount = 6
    @State private var cashSB = 10
    @State private var cashStack = 2000
    @State private var buyIn = 1000

    private var config: GameConfig {
        let format: GameFormat = isSNG
            ? .sng(SNGConfig(buyIn: buyIn, startingStack: 1500,
                             levels: [BlindLevel(sb: 10, bb: 20, hands: 12),
                                      BlindLevel(sb: 25, bb: 50, hands: 12),
                                      BlindLevel(sb: 50, bb: 100, hands: 12),
                                      BlindLevel(sb: 100, bb: 200, hands: 12)],
                             payouts: [0.5, 0.3, 0.2]))
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
                Stepper("玩家人数：\(playerCount)", value: $playerCount, in: 2...9)
                if isSNG {
                    Stepper("买入：\(buyIn)", value: $buyIn, in: 100...10000, step: 100)
                } else {
                    Stepper("小盲：\(cashSB)", value: $cashSB, in: 1...1000, step: 5)
                    Stepper("初始筹码：\(cashStack)", value: $cashStack, in: 500...100000, step: 500)
                }
                Button("开始游戏") {
                    onStart(config, UInt64(Date().timeIntervalSince1970 * 1000))
                }
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("德州扑克")
        }
    }
}
