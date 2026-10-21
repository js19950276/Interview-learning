import SwiftUI
import PokerEngine

struct GameView: View {
    @StateObject private var vm: GameViewModel
    let onExit: () -> Void

    init(session: GameSession, onExit: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: GameViewModel(config: session.config, seed: session.seed))
        self.onExit = onExit
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TableView(vm: vm)
            if vm.isSessionOver {
                sessionOverlay
            } else if vm.isHandOver {
                resultOverlay
            } else if let legal = vm.humanLegal {
                ActionBar(vm: vm, legal: legal)
            } else {
                Text("等待对手…").padding()
            }
        }
        .task { await vm.driveBots() }   // 机器人先手的开局在这里启动
    }

    private var header: some View {
        HStack {
            Button("退出") { onExit() }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if case .sng = vm.state.config.format {
                    let (sb, bb) = currentBlinds(for: vm.state.config.format, handNumber: vm.state.handNumber)
                    Text("第 \(vm.state.handNumber + 1) 手 · 盲注 \(sb)/\(bb)")
                        .font(.footnote)
                } else {
                    Text("第 \(vm.state.handNumber + 1) 手").font(.footnote)
                }
                if let last = vm.lastResult, let w = last.awards.last?.winners.first {
                    // 只计该赢家实际分得的池（多方摊牌/边池时其余池与其无关，不能记到它头上）
                    Text("上一手：\(vm.state.players[w].name) 赢 \(last.awards.filter { $0.winners.contains(w) }.reduce(0) { $0 + $1.amount })")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private var resultOverlay: some View {
        VStack(spacing: 12) {
            ForEach(vm.state.handResult?.awards ?? [], id: \.potIndex) { award in
                let names = award.winners.map { vm.state.players[$0].name }.joined(separator: "、")
                Text("\(names) 赢 \(award.amount)")
            }
            Button("下一手") { Task { await vm.nextHand() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private var sessionOverlay: some View {
        VStack(spacing: 8) {
            Text(vm.state.tournamentPayouts.isEmpty ? "会话结束" : "锦标赛结束")
                .font(.title2.bold())
            ForEach(vm.state.tournamentPayouts, id: \.place) { p in
                Text("第 \(p.place) 名 · \(vm.state.players[p.seat].name) · \(p.amount)")
            }
            Button("回到菜单") { onExit() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

private struct TableView: View {
    @ObservedObject var vm: GameViewModel

    var body: some View {
        GeometryReader { geo in
            let n = vm.state.players.count
            ZStack {
                ForEach(vm.state.players) { p in
                    let angle = Double(p.seat) / Double(n) * 2 * .pi + .pi / 2   // 座位 0 在正下方
                    SeatView(player: p,
                             isActor: vm.state.actorSeat == p.seat,
                             isButton: vm.state.buttonSeat == p.seat,
                             isHuman: p.seat == vm.state.config.humanSeat,
                             street: vm.state.street)
                        .position(x: geo.size.width / 2 + cos(angle) * geo.size.width * 0.38,
                                  y: geo.size.height / 2 + sin(angle) * geo.size.height * 0.36)
                }
                VStack(spacing: 8) {
                    Text("底池 \(vm.state.potTotal)").font(.headline)
                    HStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { i in
                            CardView(card: i < vm.state.board.count ? vm.state.board[i] : nil)
                        }
                    }
                }
            }
        }
    }
}

private struct SeatView: View {
    let player: PlayerState
    let isActor: Bool
    let isButton: Bool
    let isHuman: Bool
    let street: Street

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(player.name).font(.caption.bold())
                if isButton { Image(systemName: "circle.fill").font(.caption2) }
            }
            HStack(spacing: 3) {
                if player.holeCards.count == 2 {
                    // 弃牌者到手牌不再于 handOver 亮出（muck 不展示）
                    CardView(card: player.holeCards[0], hidden: (!isHuman && street != .handOver) || player.status == .folded)
                    CardView(card: player.holeCards[1], hidden: (!isHuman && street != .handOver) || player.status == .folded)
                } else {
                    CardView(card: nil).opacity(0.3)
                    CardView(card: nil).opacity(0.3)
                }
            }
            Text("筹码 \(player.stack)").font(.caption.monospacedDigit())
            if player.streetContribution > 0 {
                Text("投入 \(player.streetContribution)").font(.caption2).foregroundStyle(.secondary)
            }
            if player.status == .folded { Text("弃牌").font(.caption2).foregroundStyle(.red) }
            if player.status == .allIn { Text("全下").font(.caption2).foregroundStyle(.orange) }
            if player.status == .eliminated { Text("淘汰").font(.caption2).foregroundStyle(.gray) }
        }
        .padding(8)
        .background(isActor ? Color.yellow.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isActor ? .yellow : .clear))
        .opacity(player.status == .eliminated ? 0.45 : 1)   // 淘汰座位整体压暗
    }
}

private struct ActionBar: View {
    @ObservedObject var vm: GameViewModel
    let legal: LegalActions
    @State private var raiseTarget: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            if let range = legal.betRange, range.lowerBound < range.upperBound {
                HStack {
                    Text("\(legal.isRaiseContext ? "加注到" : "下注") \(Int(raiseTarget))")
                        .font(.footnote.monospacedDigit())
                    Slider(value: $raiseTarget,
                           in: Double(range.lowerBound)...Double(range.upperBound))
                }
                HStack {
                    quick("最小", Double(range.lowerBound))
                    quick("1/2 池", potTarget(vm.state.potTotal / 2))
                    quick("满池", potTarget(vm.state.potTotal))
                    quick("全下", Double(range.upperBound))
                }
            }
            HStack(spacing: 12) {
                Button("弃牌") { Task { await vm.act(.fold) } }
                    .buttonStyle(.bordered)
                if legal.canCheck {
                    Button("过牌") { Task { await vm.act(.check) } }.buttonStyle(.bordered)
                }
                if legal.canCall, legal.callAmount > 0 {
                    Button("跟注 \(legal.callAmount)") { Task { await vm.act(.call) } }
                        .buttonStyle(.bordered)
                }
                if let range = legal.betRange {
                    if range.lowerBound == range.upperBound {
                        Button("全下 \(range.upperBound)") { Task { await vm.act(.raiseTo(range.upperBound)) } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(legal.isRaiseContext ? "加注" : "下注") {
                            Task { await vm.act(.raiseTo(Int(raiseTarget))) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding()
        .background(.bar)
        .onAppear {
            if let r = legal.betRange { raiseTarget = Double(min(r.lowerBound + (r.upperBound - r.lowerBound) / 2, r.upperBound)) }
        }
    }

    private func potTarget(_ base: Int) -> Double {
        guard let r = legal.betRange else { return 0 }
        let t = Double(base + vm.state.currentBet)
        return min(max(t, Double(r.lowerBound)), Double(r.upperBound))
    }

    private func quick(_ label: String, _ target: Double) -> some View {
        Button(label) { raiseTarget = target }
            .buttonStyle(.bordered)
            .font(.caption)
    }
}

extension PlayerState: @retroactive Identifiable { public var id: Int { seat } }
