import Foundation

extension GameCore {
    nonisolated enum SupplyRules {
        static func returnToPublicSupply(
            _ resource: ResourceKind,
            amount: Int = 1,
            state: inout GameState
        ) {
            guard amount > 0 else { return }
            switch resource {
            case .coal:
                state.publicSupply.coal = capped(state.publicSupply.coal, adding: amount, cap: 30)
            case .iron:
                state.publicSupply.iron = capped(state.publicSupply.iron, adding: amount, cap: 18)
            case .beer:
                state.publicSupply.beer = capped(state.publicSupply.beer, adding: amount, cap: 15)
            }
        }

        private static func capped(_ value: Int, adding amount: Int, cap: Int) -> Int {
            let (sum, overflow) = value.addingReportingOverflow(amount)
            return overflow ? cap : min(cap, sum)
        }
    }
}
