import SwiftUI
import PokerEngine

struct CardView: View {
    let card: Card?
    var hidden = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                // 亮牌固定白底：对局界面深色背景下牌面才像真牌；牌背/空槽仍随系统底色
                .fill(card == nil || hidden ? AnyShapeStyle(.background) : AnyShapeStyle(.white))
                .shadow(radius: 2)
            if let card, !hidden {
                VStack(spacing: 2) {
                    Text(card.rankSymbol).font(.system(size: 16, weight: .bold))
                    Text(card.suitSymbol).font(.system(size: 14))
                }
                .foregroundColor([Suit.heart, .diamond].contains(card.suit) ? .red : .black)
            } else if hidden {
                Image(systemName: "questionmark").foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 50)
    }
}

/// 编译器强制偏差：引擎 `Rank.symbol`/`Suit.symbol` 为 internal（Card.swift 无 public），
/// 跨模块不可访问；故在 UI 本地做同样的显示映射，保持引擎源码与本任务提交范围（PokerApp）不变。
private extension Card {
    var rankSymbol: String {
        switch rank {
        case .ace: return "A"
        case .king: return "K"
        case .queen: return "Q"
        case .jack: return "J"
        case .ten: return "T"
        default: return String(rank.rawValue)
        }
    }
    var suitSymbol: String { ["♠", "♥", "♦", "♣"][suit.rawValue] }
}
