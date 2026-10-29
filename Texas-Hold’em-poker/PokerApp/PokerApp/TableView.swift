import SwiftUI
import PokerEngine

struct GameView<VM: GamePresenting>: View {
    @ObservedObject var vm: VM
    let onExit: () -> Void

    var body: some View {
        ZStack {
            tableBackground
            if let surface = vm.surface {
                VStack(spacing: 0) {
                    header(surface: surface)
                    ZStack {
                        TableView(vm: vm, surface: surface)
                        if vm.isSessionOver {
                            sessionOverlay(surface: surface)
                        } else if vm.isHandOver {
                            resultOverlay(surface: surface)
                        }
                    }
                    ActionBar(vm: vm)   // 常驻底部：行结构恒定 → 高度恒定，桌面不再被顶起
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 桌面照片整体偏暗，对局界面固定深色，浅色模式的黑字压在照片上不可读
        .environment(\.colorScheme, .dark)
        .task { await vm.driveBots() }   // 机器人先手的开局在这里启动（联机 VM 为空实现）
    }

    /// 全屏俯拍扑克桌照片做背景，叠深色遮罩压暗，保证座位/底池/公共牌文字可读。
    private var tableBackground: some View {
        GeometryReader { geo in
            Image("poker-table-bg")
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .overlay(Color.black.opacity(0.30))
        }
        .ignoresSafeArea()
    }

    private func header(surface: any TableSurface) -> some View {
        HStack {
            Button("退出") { onExit() }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if case .sng = surface.format {
                    let (sb, bb) = currentBlinds(for: surface.format, handNumber: surface.handNumber)
                    Text("第 \(surface.handNumber + 1) 手 · 盲注 \(sb)/\(bb)")
                        .font(.footnote)
                } else {
                    Text("第 \(surface.handNumber + 1) 手").font(.footnote)
                }
                if let last = vm.lastResult,
                   let w = last.awards.last?.winners.first,
                   let winner = surface.seatPlayer(w) {
                    // 只计该赢家实际分得的池（多方摊牌/边池时其余池与其无关，不能记到它头上）
                    Text("上一手：\(winner.name) 赢 \(last.awards.filter { $0.winners.contains(w) }.reduce(0) { $0 + $1.amount })")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private func resultOverlay(surface: any TableSurface) -> some View {
        VStack(spacing: 12) {
            ForEach(surface.handResult?.awards ?? [], id: \.potIndex) { award in
                let names = award.winners.compactMap { surface.seatPlayer($0)?.name }.joined(separator: "、")
                Text("\(names) 赢 \(award.amount)")
            }
            Button("下一手") { Task { await vm.nextHand() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private func sessionOverlay(surface: any TableSurface) -> some View {
        VStack(spacing: 8) {
            Text(surface.tournamentPayouts.isEmpty ? "会话结束" : "锦标赛结束")
                .font(.title2.bold())
            ForEach(surface.tournamentPayouts, id: \.place) { p in
                Text("第 \(p.place) 名 · \(surface.seatPlayer(p.seat)?.name ?? "?") · \(p.amount)")
            }
            Button("回到菜单") { onExit() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

private struct TableView<VM: GamePresenting>: View {
    @ObservedObject var vm: VM
    let surface: any TableSurface

    var body: some View {
        GeometryReader { geo in
            let n = surface.seats.count
            ZStack {
                ForEach(surface.seats, id: \.seat) { p in
                    let angle = Double(p.seat) / Double(n) * 2 * .pi + .pi / 2   // 座位 0 在正下方
                    SeatView(player: p,
                             isActor: surface.actorSeat == p.seat,
                             isButton: surface.buttonSeat == p.seat,
                             isHuman: p.seat == surface.yourSeat,
                             street: surface.street)
                        .position(x: geo.size.width / 2 + cos(angle) * geo.size.width * 0.38,
                                  y: geo.size.height / 2 + sin(angle) * geo.size.height * 0.36)
                }
                VStack(spacing: 8) {
                    Text("底池 \(surface.potTotal)").font(.headline)
                    HStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { i in
                            CardView(card: i < surface.board.count ? surface.board[i] : nil)
                        }
                    }
                }
            }
        }
    }
}

private struct SeatView: View {
    let player: any SeatSurface
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
                } else if player.holdsCards {
                    // 快照里不可见的对手手牌：画牌背（联机路径独有状态）
                    CardView(card: nil, hidden: true)
                    CardView(card: nil, hidden: true)
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

/// 常驻底部操作栏：三行结构（滑块/快捷额度/动作按钮）永远渲染，
/// 非你回合整套禁用压暗——高度恒定，桌面不会因它出现/消失而上下浮动。
private struct ActionBar<VM: GamePresenting>: View {
    @ObservedObject var vm: VM
    @State private var raiseTarget: Double = 0

    private var legal: LegalActions? { vm.humanLegal }
    private var active: Bool { legal != nil }
    private var potTotal: Int { vm.surface?.potTotal ?? 0 }
    private var currentBet: Int { vm.surface?.currentBet ?? 0 }

    /// 可用加注区间（下界==上界的仅全下局面没有滑块调节的意义）
    private var range: ClosedRange<Int>? {
        guard let r = legal?.betRange, r.lowerBound < r.upperBound else { return nil }
        return r
    }

    /// 非你回合时占据额度标签位置的状态文案
    private var statusText: String {
        if vm.isSessionOver { return "会话结束" }
        if vm.isHandOver { return "本手结束" }
        return "等待对手…"
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                if !active {
                    Text(statusText).font(.footnote)
                } else if legal?.betRange == nil {
                    Text("无法加注").font(.footnote)          // 面对超过身家的全下：只能弃/跟
                } else if range == nil {
                    Text("仅剩全下").font(.footnote)          // 下界==上界：无可调区间
                } else {
                    Text("\(legal?.isRaiseContext == true ? "加注到" : "下注") \(Int(raiseTarget))")
                        .font(.footnote.monospacedDigit())
                }
                Slider(value: $raiseTarget,
                       in: range.map { Double($0.lowerBound)...Double($0.upperBound) } ?? 0...1)
                    .disabled(range == nil)
                    .opacity(range == nil ? 0.35 : 1)
            }
            HStack {
                quick("最小", Double(range?.lowerBound ?? 0))
                quick("1/2 池", potTarget(potTotal / 2))
                quick("满池", potTarget(potTotal))
                quick("全下", Double(range?.upperBound ?? 0))
            }
            .disabled(range == nil)
            .opacity(range == nil ? 0.35 : 1)
            HStack(spacing: 12) {
                if let legal {
                    liveButtons(legal)
                } else {
                    skeletonButtons
                }
            }
            .disabled(!active)
            .opacity(active ? 1 : 0.35)
        }
        .padding()
        .background(.bar)
        // 常驻后不再按回合重挂载：新回合/新街道都要重算滑块目标，防上一局的额度残留成非法加注
        .onAppear { syncRaiseTarget() }
        .onChange(of: legal) { _, _ in syncRaiseTarget() }
    }

    @ViewBuilder
    private func liveButtons(_ legal: LegalActions) -> some View {
        Button("弃牌") { Task { await vm.act(.fold) } }
            .buttonStyle(.bordered)
        if legal.canCheck {
            Button("过牌") { Task { await vm.act(.check) } }.buttonStyle(.bordered)
        }
        if legal.canCall, legal.callAmount > 0 {
            Button("跟注 \(legal.callAmount)") { Task { await vm.act(.call) } }
                .buttonStyle(.bordered)
        }
        if let r = legal.betRange {
            if r.lowerBound == r.upperBound {
                Button("全下 \(r.upperBound)") { Task { await vm.act(.raiseTo(r.upperBound)) } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(legal.isRaiseContext ? "加注" : "下注") {
                    Task { await vm.act(.raiseTo(Int(raiseTarget))) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// 非你回合的占位按钮组：与 liveButtons 同款样式，只为撑住行高
    private var skeletonButtons: some View {
        HStack(spacing: 12) {
            Button("弃牌") {}.buttonStyle(.bordered)
            Button("过牌") {}.buttonStyle(.bordered)
            Button("跟注") {}.buttonStyle(.bordered)
            Button("加注") {}.buttonStyle(.borderedProminent)
        }
    }

    private func syncRaiseTarget() {
        guard let r = range else { return }
        raiseTarget = Double(min(r.lowerBound + (r.upperBound - r.lowerBound) / 2, r.upperBound))
    }

    private func potTarget(_ base: Int) -> Double {
        guard let r = range else { return 0 }
        let t = Double(base + currentBet)
        return min(max(t, Double(r.lowerBound)), Double(r.upperBound))
    }

    private func quick(_ label: String, _ target: Double) -> some View {
        Button(label) { raiseTarget = target }
            .buttonStyle(.bordered)
            .font(.caption)
    }
}

extension PlayerState: @retroactive Identifiable { public var id: Int { seat } }
