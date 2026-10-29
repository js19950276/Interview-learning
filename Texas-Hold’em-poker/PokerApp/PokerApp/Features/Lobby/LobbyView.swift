import SwiftUI
import PokerEngine

/// 联机入口：创建房间 / 搜索加入。
struct LobbyView: View {
    let onHost: (HostGameViewModel) -> Void
    let onGuest: (GuestGameViewModel) -> Void
    @State private var mode: Mode = .menu

    private enum Mode: Hashable { case menu, hostSetup, joinBrowse }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .menu: menuScreen
                case .hostSetup: HostSetupView(onCreate: { vm in onHost(vm) })
                case .joinBrowse: JoinRoomView(onJoin: { vm in onGuest(vm) })
                }
            }
            .navigationTitle("联机对战")
        }
    }

    private var menuScreen: some View {
        VStack(spacing: 16) {
            Button("创建房间") { mode = .hostSetup }
                .buttonStyle(.borderedProminent)
            Button("搜索附近房间") { mode = .joinBrowse }
                .buttonStyle(.bordered)
            Text("同一 Wi-Fi 下即可游玩；无路由器时也可用点对点 Wi-Fi 直连。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// 房主建房表单（复用单机的桌子配置项；人数由入座人数决定）。
private struct HostSetupView: View {
    let onCreate: (HostGameViewModel) -> Void
    @State private var roomName = "周五德州桌"
    @State private var hostName = ""
    @State private var isSNG = false
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
        return GameConfig(playerCount: 2, startingStack: isSNG ? 1500 : cashStack, format: format)
    }

    var body: some View {
        Form {
            TextField("房间名", text: $roomName)
            TextField("你的名字（可留空）", text: $hostName)
            Picker("模式", selection: $isSNG) {
                Text("现金局").tag(false)
                Text("单桌锦标赛 SNG").tag(true)
            }
            if isSNG {
                Stepper("买入：\(buyIn)", value: $buyIn, in: 100...10000, step: 100)
            } else {
                Stepper("小盲：\(cashSB)", value: $cashSB, in: 1...1000, step: 5)
                Stepper("初始筹码：\(cashStack)", value: $cashStack, in: 500...100000, step: 500)
            }
            Button("开始广播房间") {
                let vm = HostGameViewModel(configuration: HostConfiguration(
                    roomName: roomName, hostName: hostName, tableConfig: config))
                onCreate(vm)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// 房主大厅：名册/ready/开局。开局后由 HostRoomOrGameView 切到 GameView。
private struct HostRoomView: View {
    @ObservedObject var vm: HostGameViewModel
    let onExit: () -> Void
    @State private var ready = false

    var body: some View {
        VStack(spacing: 12) {
            if let issue = vm.issue {
                Text(issue).font(.footnote).foregroundStyle(.red)
            }
            if let lobby = vm.lobby {
                Text("房间：\(lobby.roomName)").font(.headline)
                List {
                    ForEach(lobby.players, id: \.seat) { player in
                        HStack {
                            Text(player.name)
                            if player.isHost { Text("房主").font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            if !player.connected { Text("离线").font(.caption2).foregroundStyle(.red) }
                            else if player.ready { Text("已准备").font(.caption2).foregroundStyle(.green) }
                            else { Text("未准备").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                Toggle("我已准备", isOn: $ready)
                    .onChange(of: ready) { _, value in Task { await vm.setReady(value) } }
                Button(vm.canStartGame ? "开局" : "等待全员准备（至少 2 人）…") {
                    Task { await vm.startGame() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canStartGame)
            } else {
                ProgressView("正在创建房间…")
            }
            Spacer()
            Button("退出房间", role: .destructive) { onExit() }
        }
        .padding()
        .task { await vm.start() }
    }
}

/// 客机搜房 + 加入。
private struct JoinRoomView: View {
    let onJoin: (GuestGameViewModel) -> Void
    @StateObject private var browser = RoomBrowserModel()
    @State private var name = ""

    var body: some View {
        VStack(spacing: 12) {
            TextField("你的名字（可留空）", text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            if let issue = browser.issue {
                Text(issue).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            if browser.rooms.isEmpty {
                if browser.searching { ProgressView("正在搜索附近房间…") }
                else { Text("附近暂无房间，让房主先创建").font(.footnote).foregroundStyle(.secondary) }
            } else {
                List(browser.rooms) { room in
                    Button {
                        let vm = GuestGameViewModel(roomID: room.roomID,
                                                    displayName: name.isEmpty ? "玩家" : name)
                        onJoin(vm)
                    } label: {
                        Text(room.serviceName)
                    }
                }
            }
        }
        .task { browser.start() }
        .onDisappear { browser.stop() }
    }
}

/// 客机大厅（名册 + ready）；收到首帧快照后由 GuestRoomOrGameView 切到 GameView。
private struct GuestRoomView: View {
    @ObservedObject var vm: GuestGameViewModel
    let onExit: () -> Void
    @State private var ready = false

    var body: some View {
        VStack(spacing: 12) {
            if let fatal = vm.fatal {
                Text(fatal).font(.footnote).foregroundStyle(.red)
            } else if let lobby = vm.lobby {
                Text("房间：\(lobby.roomName)").font(.headline)
                List {
                    ForEach(lobby.players, id: \.seat) { player in
                        HStack {
                            Text(player.name)
                            if player.isHost { Text("房主").font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            if !player.connected { Text("离线").font(.caption2).foregroundStyle(.red) }
                            else if player.ready { Text("已准备").font(.caption2).foregroundStyle(.green) }
                            else { Text("未准备").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                if vm.reconnecting { Text("连接断开，重连中…").font(.footnote).foregroundStyle(.red) }
                Toggle("我已准备", isOn: $ready)
                    .onChange(of: ready) { _, value in Task { await vm.setReady(value) } }
            } else {
                ProgressView("正在加入…")
            }
            Spacer()
            Button("返回大厅", role: .destructive) { onExit() }
        }
        .padding()
        .task { await vm.join() }
    }
}

/// 大厅↔牌桌切换由 VM 的 @Published 状态驱动（根路由只持有 VM，不直接观察；这里用 @ObservedObject 感知）。
struct HostRoomOrGameView: View {
    @ObservedObject var vm: HostGameViewModel
    let onExit: () -> Void

    var body: some View {
        if vm.gameState != nil {
            GameView(vm: vm, onExit: onExit)
        } else {
            HostRoomView(vm: vm, onExit: onExit)
        }
    }
}

struct GuestRoomOrGameView: View {
    @ObservedObject var vm: GuestGameViewModel
    let onExit: () -> Void

    var body: some View {
        if vm.inGame {
            GameView(vm: vm, onExit: onExit)
                .overlay(alignment: .top) {
                    // 断线重连横幅 + 动作被拒等瞬态提示（spec §10.2）
                    VStack(spacing: 4) {
                        if vm.reconnecting {
                            Text("连接断开，重连中…").font(.footnote).padding(8)
                                .background(.red.opacity(0.85), in: Capsule())
                        }
                        if let warning = vm.warning {
                            Text(warning).font(.footnote).padding(8)
                                .background(.orange.opacity(0.85), in: Capsule())
                        }
                    }
                    .padding(.top, 4)
                }
        } else {
            GuestRoomView(vm: vm, onExit: onExit)
        }
    }
}
