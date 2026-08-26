import Foundation

nonisolated struct ActiveTurnPresentation: Equatable, Sendable {
    let playerID: String
    let playerName: String
    let playerColor: PlayerColor
    let isLocalPlayer: Bool

    var headerText: String {
        isLocalPlayer ? "轮到你 · \(playerName)" : "等待 \(playerName)"
    }

    var noticeText: String {
        isLocalPlayer ? "轮到你了" : "现在轮到 \(playerName)"
    }

    var accessibilityLabel: String {
        "\(headerText)，\(playerColor.localizedName)，\(playerColor.localizedShapeName)"
    }

    static func make(players: [PlayerSummary], localPlayerID: String) -> Self? {
        guard let player = players.first(where: \.isCurrent) else { return nil }
        return .init(
            playerID: player.id,
            playerName: player.name,
            playerColor: player.color,
            isLocalPlayer: player.id == localPlayerID
        )
    }
}

nonisolated struct ActiveTurnNoticeTracker: Equatable, Sendable {
    private(set) var lastPresentedPlayerID: String?
    private(set) var wasSynchronized = false

    mutating func consume(playerID: String?, isSynchronized: Bool) -> Bool {
        guard isSynchronized, let playerID else {
            wasSynchronized = false
            return false
        }
        let shouldPresent = !wasSynchronized || lastPresentedPlayerID != playerID
        wasSynchronized = true
        lastPresentedPlayerID = playerID
        return shouldPresent
    }
}

extension PlayerColor {
    nonisolated var localizedName: String {
        switch self {
        case .amber: "琥珀色"
        case .crimson: "深红色"
        case .teal: "青绿色"
        case .violet: "紫罗兰色"
        }
    }

    nonisolated var localizedShapeName: String {
        switch self {
        case .amber: "菱形标记"
        case .crimson: "三角形标记"
        case .teal: "圆形标记"
        case .violet: "方形标记"
        }
    }
}
