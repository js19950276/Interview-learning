import CoreGraphics
import Observation

enum MatchOverlay: Equatable {
    case playerRail
    case industryRail
    case resourceMarket
    case actionGrid
}

enum NetworkCount: Int, Equatable {
    case one = 1
    case two = 2
}

struct BuildDraft: Equatable {
    var locationID: String?
}

struct NetworkDraft: Equatable {
    var count: NetworkCount = .one
    var routeIDs: [String] = []
}

struct DevelopDraft: Equatable {
    var industryIDs: [String] = []
}

struct SellDraft: Equatable {
    var optionIDs: [String] = []
    var focusedIndustryID: String?
}

struct ScoutDraft: Equatable {
    var extraCardIDs: [String] = []
}

enum ActionFlowState: Equatable {
    case idle
    case build(BuildDraft)
    case network(NetworkDraft)
    case develop(DevelopDraft)
    case sell(SellDraft)
    case loan
    case scout(ScoutDraft)
    case pass

    static func start(_ action: GameAction) -> ActionFlowState {
        switch action {
        case .build: .build(BuildDraft())
        case .network: .network(NetworkDraft())
        case .develop: .develop(DevelopDraft())
        case .sell: .sell(SellDraft())
        case .loan: .loan
        case .scout: .scout(ScoutDraft())
        case .pass: .pass
        }
    }
}

extension ActionFlowState {
    var isConfirmable: Bool {
        switch self {
        case .idle:
            false
        case .build(let draft):
            draft.locationID != nil
        case .network(let draft):
            draft.routeIDs.count == draft.count.rawValue
        case .develop(let draft):
            (1...2).contains(draft.industryIDs.count)
        case .sell(let draft):
            draft.optionIDs.isEmpty == false
        case .loan, .pass:
            true
        case .scout(let draft):
            draft.extraCardIDs.count == 2
        }
    }

    var usesMapTargets: Bool {
        switch self {
        case .build, .network, .sell:
            true
        case .idle, .develop, .loan, .scout, .pass:
            false
        }
    }
}

@MainActor
@Observable
final class MatchInteractionReducer {
    private(set) var selectedCardID: String?
    private(set) var selectedAction: GameAction?
    private(set) var overlay: MatchOverlay?
    private(set) var flow: ActionFlowState = .idle

    static func drawerWidth(viewportWidth: CGFloat) -> CGFloat {
        min(viewportWidth * 0.42, 360)
    }

    func selectCard(_ id: String) {
        if selectedCardID != id {
            selectedCardID = id
            selectedAction = nil
            flow = .idle
        }
        overlay = nil
    }

    func toggleOverlay(_ candidate: MatchOverlay) {
        overlay = overlay == candidate ? nil : candidate
    }

    func dismissOverlay() {
        overlay = nil
    }

    func selectAction(_ action: GameAction) {
        selectedAction = action
        overlay = nil
        flow = ActionFlowState.start(action)
    }

    func cancelFlow() {
        selectedAction = nil
        flow = .idle
    }

    func resetSelection() {
        selectedCardID = nil
        selectedAction = nil
        overlay = nil
        flow = .idle
    }

    func confirmFlow() {
        guard flow.isConfirmable else { return }
        selectedAction = nil
        flow = .idle
    }

#if DEBUG
    func confirmedIntent() -> DemoIntent? {
        guard flow.isConfirmable,
              let action = selectedAction,
              let selectedCardID else { return nil }

        let targetIDs: [String] = switch flow {
        case .build(let draft):
            [draft.locationID].compactMap { $0 }
        case .network(let draft):
            draft.routeIDs
        case .develop(let draft):
            draft.industryIDs
        case .sell(let draft):
            draft.optionIDs
        case .scout(let draft):
            draft.extraCardIDs
        case .loan, .pass:
            []
        case .idle:
            []
        }

        return DemoIntent(
            action: action,
            selectedCardID: selectedCardID,
            targetIDs: targetIDs
        )
    }

    func selectBuildLocation(_ id: String, fixture: ActionFixture) {
        guard fixture.buildLocationIDs.contains(id) else { return }
        flow = .build(BuildDraft(locationID: id))
    }

    func toggleDevelopIndustry(_ id: String, fixture: ActionFixture) {
        guard fixture.developIndustryIDs.contains(id) else { return }
        guard case .develop(var draft) = flow else { return }

        if let index = draft.industryIDs.firstIndex(of: id) {
            draft.industryIDs.remove(at: index)
        } else if draft.industryIDs.count < 2 {
            draft.industryIDs.append(id)
        }

        flow = .develop(draft)
    }

    func toggleScoutCard(_ id: String, fixture: ActionFixture) {
        guard id != selectedCardID else { return }
        guard fixture.scoutCardIDs.contains(id) else { return }
        guard case .scout(var draft) = flow else { return }
        if let index = draft.extraCardIDs.firstIndex(of: id) {
            draft.extraCardIDs.remove(at: index)
        } else if draft.extraCardIDs.count < 2 {
            draft.extraCardIDs.append(id)
        }
        flow = .scout(draft)
    }

    func toggleSaleOption(_ id: String, fixture: ActionFixture) {
        guard fixture.sellOptions.contains(where: { $0.id == id }) else { return }
        guard case .sell(var draft) = flow else { return }

        if let index = draft.optionIDs.firstIndex(of: id) {
            draft.optionIDs.remove(at: index)
        } else {
            draft.optionIDs.append(id)
        }

        flow = .sell(draft)
    }

    func selectSaleIndustry(_ id: String, fixture: ActionFixture) {
        guard fixture.sellOptions.contains(where: { $0.industryID == id }) else { return }
        guard case .sell(var draft) = flow else { return }
        draft.focusedIndustryID = id
        flow = .sell(draft)
    }

    func setNetworkCount(_ count: NetworkCount) {
        flow = .network(NetworkDraft(count: count, routeIDs: []))
    }

    func appendNetworkRoute(_ id: String, fixture: ActionFixture, routes: [MapRoute]) {
        guard case .network(var draft) = flow else { return }
        guard highlightedTargetIDs(fixture: fixture, routes: routes).contains(id) else { return }
        draft.routeIDs.append(id)
        flow = .network(draft)
    }

    func highlightedTargetIDs(fixture: ActionFixture, routes: [MapRoute]) -> Set<String> {
        switch flow {
        case .build:
            return Set(fixture.buildLocationIDs)
        case .network(let draft):
            guard draft.routeIDs.count < draft.count.rawValue else { return [] }
            guard let firstRouteID = draft.routeIDs.first else {
                return Set(fixture.networkRouteIDs)
            }
            guard let firstRoute = routes.first(where: { $0.id == firstRouteID }) else { return [] }

            let endpoints = Set([firstRoute.fromLocationID, firstRoute.toLocationID])
            return Set(
                routes
                    .filter { fixture.networkRouteIDs.contains($0.id) }
                    .filter { draft.routeIDs.contains($0.id) == false }
                    .filter {
                        endpoints.contains($0.fromLocationID) || endpoints.contains($0.toLocationID)
                    }
                    .map(\.id)
            )
        case .idle, .develop, .sell, .loan, .scout, .pass:
            return []
        }
    }
#endif
}
