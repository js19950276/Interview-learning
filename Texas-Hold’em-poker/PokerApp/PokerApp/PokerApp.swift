import SwiftUI
import PokerEngine

@main
struct PokerApp: App {
    @State private var localVM: GameViewModel?
    @State private var hostVM: HostGameViewModel?
    @State private var guestVM: GuestGameViewModel?
    @State private var showingLobby = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            root
                .sheet(isPresented: $showingLobby) {
                    LobbyView(onHost: { vm in
                        hostVM = vm
                        showingLobby = false
                    }, onGuest: { vm in
                        guestVM = vm
                        showingLobby = false
                    })
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await hostVM?.applicationDidBecomeActive()
                        await guestVM?.applicationDidBecomeActive()
                    }
                }
        }
    }

    @ViewBuilder
    private var root: some View {
        if let hostVM {
            // 大厅/牌桌切换在包装视图内由 VM 状态驱动；退出只置 nil → VM deinit 断开会话
            HostRoomOrGameView(vm: hostVM, onExit: { self.hostVM = nil })
        } else if let guestVM {
            GuestRoomOrGameView(vm: guestVM, onExit: { self.guestVM = nil })
        } else if let localVM {
            GameView(vm: localVM, onExit: { self.localVM = nil })
        } else {
            MenuView(onStart: { config, seed, difficulty in
                self.localVM = GameViewModel(config: config, seed: seed, ai: difficulty)
            }, onMultiplayer: {
                showingLobby = true
            })
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
