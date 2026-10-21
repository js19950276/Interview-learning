import SwiftUI
import PokerEngine

@main
struct PokerApp: App {
    @State private var session: GameSession?

    var body: some Scene {
        WindowGroup {
            if let session {
                GameView(session: session) { self.session = nil }
            } else {
                MenuView { config, seed in
                    session = GameSession(config: config, seed: seed)
                }
            }
        }
    }
}

/// 一场会话（配置 + 种子）。
struct GameSession: Identifiable {
    let id = UUID()
    let config: GameConfig
    let seed: UInt64
}

/// Task 13 替换为完整牌桌。
struct GameView: View {
    let session: GameSession
    let onExit: () -> Void

    var body: some View {
        Text("牌桌（Task 13）")
    }
}
