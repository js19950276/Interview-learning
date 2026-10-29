import SwiftUI
import PokerEngine

@main
struct PokerApp: App {
    @State private var localVM: GameViewModel?

    var body: some Scene {
        WindowGroup {
            if let localVM {
                GameView(vm: localVM, onExit: { self.localVM = nil })
            } else {
                MenuView(onStart: { config, seed, difficulty in
                    self.localVM = GameViewModel(config: config, seed: seed, ai: difficulty)
                }, onMultiplayer: { })
            }
        }
    }
}

/// 一场会话（配置 + 种子 + AI 难度档）。
struct GameSession: Identifiable {
    let id = UUID()
    let config: GameConfig
    let seed: UInt64
    var difficulty: AIDifficulty = .baseline
}
