import SwiftUI

nonisolated enum ActionDisplay {
    static func title(for action: GameAction) -> String {
        switch action {
        case .build: "建造"
        case .network: "铺设"
        case .develop: "研发"
        case .sell: "出售"
        case .loan: "贷款"
        case .scout: "侦察"
        case .pass: "跳过"
        }
    }

    static func symbol(for action: GameAction) -> String {
        switch action {
        case .build: "building.2.fill"
        case .network: "point.topleft.down.to.point.bottomright.curvepath"
        case .develop: "arrow.up.right.square.fill"
        case .sell: "sterlingsign.circle.fill"
        case .loan: "banknote.fill"
        case .scout: "binoculars.fill"
        case .pass: "forward.end.fill"
        }
    }
}

nonisolated struct ActionContextProgress: Equatable, Sendable {
    let current: Int
    let total: Int

    init(current: Int, total: Int) {
        self.current = current
        self.total = total
    }

    init?(
        era: GameCore.Era,
        roundNumber: Int,
        actionsRemaining: Int
    ) {
        let total = GameCore.TurnRules.actionsPerTurn(
            era: era,
            roundNumber: roundNumber
        )
        guard (1...total).contains(actionsRemaining) else { return nil }

        self.current = total - actionsRemaining + 1
        self.total = total
    }
}

struct ActionContextBar: View {
    let currentActionNumber: Int
    let totalActions: Int
    let action: GameAction
    let instruction: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label("行动 \(currentActionNumber)/\(totalActions)", systemImage: "bolt.fill")
                .font(BrassTypography.number)
                .foregroundStyle(BrassColor.coal.color)

            Divider()
                .frame(height: 24)
                .overlay(BrassColor.coal.color.opacity(0.35))

            Label(Self.title(for: action), systemImage: ActionDisplay.symbol(for: action))
                .font(BrassTypography.label)
                .foregroundStyle(BrassColor.coal.color)

            Text(instruction)
                .font(BrassTypography.label)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
                .foregroundStyle(BrassColor.coal.color.opacity(0.82))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(BrassColor.danger.color)
            .accessibilityLabel("取消")
            .accessibilityIdentifier("action.context.cancel")
        }
        .frame(minHeight: 44)
        .modifier(ParchmentContextSurface())
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("行动 \(currentActionNumber)/\(totalActions)，\(Self.title(for: action))，\(instruction)")
        .accessibilityIdentifier("action.context")
    }

    static func title(for action: GameAction) -> String {
        ActionDisplay.title(for: action)
    }

    static func instruction(
        for action: GameAction,
        selectionLabels: [String],
        choices: [GameCore.LegalChoice]
    ) -> String {
        let prefix = selectionLabels.isEmpty ? "" : "已选 \(selectionLabels.count) 项，"
        if choices.contains(where: { choice in isBuildTarget(choice.value) }) {
            return prefix + "选择城市"
        }
        if choices.contains(where: { choice in isRoute(choice.value) }) {
            return prefix + "继续选择路线"
        }
        if choices.contains(where: { choice in isIndustryTile(choice.value) }) {
            return prefix + "选择产业"
        }
        if choices.contains(where: { choice in isMerchant(choice.value) }) {
            return prefix + "选择贸易商"
        }
        if choices.contains(where: { choice in isIndustryPlacement(choice.value) }) {
            return prefix + "选择产业"
        }
        if choices.contains(where: { choice in isResourceSource(choice.value) }) {
            return prefix + resourceSourceInstruction(for: action, choices: choices)
        }
        if choices.contains(where: { choice in isCard(choice.value) }) {
            return prefix + "选择额外手牌"
        }

        return switch action {
        case .build: prefix + "选择城市"
        case .network: prefix + "选择路线"
        case .develop: prefix + "选择产业"
        case .sell: prefix + "选择贸易商"
        case .loan: "确认贷款"
        case .scout: prefix + "选择额外手牌"
        case .pass: "确认跳过"
        }
    }

    private static func isBuildTarget(_ value: GameCore.LegalChoiceValue) -> Bool {
        if case .buildTarget = value { return true }
        return false
    }

    private static func isRoute(_ value: GameCore.LegalChoiceValue) -> Bool {
        if case .route = value { return true }
        return false
    }

    private static func isIndustryTile(_ value: GameCore.LegalChoiceValue) -> Bool {
        if case .industryTile = value { return true }
        return false
    }

    private static func isMerchant(_ value: GameCore.LegalChoiceValue) -> Bool {
        if case .merchant = value { return true }
        return false
    }

    private static func isIndustryPlacement(_ value: GameCore.LegalChoiceValue) -> Bool {
        if case .industryPlacement = value { return true }
        return false
    }

    private static func isCard(_ value: GameCore.LegalChoiceValue) -> Bool {
        if case .card = value { return true }
        return false
    }

    private static func isResourceSource(_ value: GameCore.LegalChoiceValue) -> Bool {
        if case .resourceSource = value { return true }
        return false
    }

    private static func resourceSourceInstruction(
        for action: GameAction,
        choices: [GameCore.LegalChoice]
    ) -> String {
        switch action {
        case .sell:
            return "选择啤酒来源"
        case .develop:
            return "选择钢铁来源"
        case .network:
            let isBeer = choices.contains { choice in
                if case .resourceSource(.merchantBeer) = choice.value { return true }
                return choice.label.contains("啤酒")
            }
            return isBeer ? "选择啤酒来源" : "选择煤炭来源"
        case .build:
            if choices.contains(where: { $0.label.contains("煤") }) {
                return "选择煤炭来源"
            }
            if choices.contains(where: { $0.label.contains("铁") }) {
                return "选择钢铁来源"
            }
            return "选择资源来源"
        case .loan, .scout, .pass:
            return "选择资源来源"
        }
    }
}
