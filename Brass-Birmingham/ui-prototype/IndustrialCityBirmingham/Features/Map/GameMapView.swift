import SpriteKit
import SwiftUI

nonisolated struct MapLegendInsets: Equatable, Sendable {
    static let zero = MapLegendInsets(top: 0, trailing: 0)

    let top: CGFloat
    let trailing: CGFloat
}

nonisolated struct GameMapAccessibilityTarget: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
}

nonisolated enum GameMapTapRoute: Equatable, Sendable {
    case target(String)
    case background
}

nonisolated struct MapTapRoutingState: Equatable, Sendable {
    private var physicalTap: GameMapTapRoute?
    private var receivedAccessibilityActivation = false

    mutating func recordPhysicalTap(_ route: GameMapTapRoute) {
        physicalTap = route
    }

    mutating func recordAccessibilityActivation() {
        receivedAccessibilityActivation = true
    }

    mutating func resolve() -> GameMapTapRoute? {
        defer {
            physicalTap = nil
            receivedAccessibilityActivation = false
        }
        guard receivedAccessibilityActivation == false else { return nil }
        return physicalTap
    }
}

nonisolated enum MapMerchantAccessibility {
    static func label(locationName: String, merchant: MapMerchantPlacement) -> String {
        let beerAndReward: String
        if merchant.acceptedIndustries.isEmpty {
            beerAndReward = "无贸易商啤酒，奖励不可用"
        } else if merchant.hasBeer {
            beerAndReward = "贸易商啤酒可用，\(rewardLabel(for: merchant))"
        } else {
            beerAndReward = "贸易商啤酒已用尽，奖励不可用"
        }
        return [locationName, acceptanceLabel(for: merchant), beerAndReward]
            .joined(separator: "，")
    }

    private static func acceptanceLabel(for merchant: MapMerchantPlacement) -> String {
        let industries = merchant.acceptedIndustries
        if industries.isEmpty {
            return "空白贸易商"
        }
        if industries.contains(.cotton),
           industries.contains(.manufacturer),
           industries.contains(.pottery) {
            return "任意制成品"
        }
        return industries.map(industryLabel).joined(separator: "、")
    }

    private static func industryLabel(_ industry: IndustryKind) -> String {
        switch industry {
        case .cotton: "棉纺厂"
        case .manufacturer: "制造厂"
        case .pottery: "陶瓷厂"
        case .coal: "煤矿"
        case .iron: "炼铁厂"
        case .brewery: "啤酒厂"
        }
    }

    private static func rewardLabel(for merchant: MapMerchantPlacement) -> String {
        switch merchant.bonusKind {
        case .develop: "开发 +\(merchant.bonusAmount)"
        case .income: "收入 +\(merchant.bonusAmount)"
        case .money: "金钱 +\(merchant.bonusAmount)"
        case .victoryPoints: "胜利点 +\(merchant.bonusAmount)"
        }
    }
}

nonisolated enum MapIndustryAccessibility {
    static func label(
        locationName: String,
        ordinal: Int,
        placement: MapIndustryPlacement,
        ownerName: String
    ) -> String {
        [
            locationName,
            "第\(ordinal)个产业",
            industryLabel(placement.kind),
            "等级\(placement.level)",
            statusLabel(placement),
            "所有者 \(ownerName)",
        ].joined(separator: "，")
    }

    private static func industryLabel(_ industry: IndustryKind) -> String {
        switch industry {
        case .cotton: "棉纺厂"
        case .manufacturer: "制造厂"
        case .pottery: "陶瓷厂"
        case .coal: "煤矿"
        case .iron: "炼铁厂"
        case .brewery: "啤酒厂"
        }
    }

    private static func statusLabel(_ placement: MapIndustryPlacement) -> String {
        if placement.isFlipped {
            return "已翻面"
        }
        switch placement.kind {
        case .coal, .iron, .brewery:
            return "剩余资源\(placement.resourceCount)"
        case .cotton, .manufacturer, .pottery:
            return "未翻面"
        }
    }
}

nonisolated enum GameMapAccessibility {
    static func targets(
        state: DemoMatchState,
        highlightedIDs: Set<String>
    ) -> [GameMapAccessibilityTarget] {
        let locations = state.locations
            .filter { highlightedIDs.contains($0.id) }
            .map { GameMapAccessibilityTarget(id: $0.id, label: $0.name) }
        let namesByID = Dictionary(uniqueKeysWithValues: state.locations.map { ($0.id, $0.name) })
        let playersByID = Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, $0.name) })
        let currentEra = MapRouteEraStyle.currentEra(from: state.era)
        let routes = state.routes
            .filter { highlightedIDs.contains($0.id) }
            .map { route in
                let start = namesByID[route.fromLocationID] ?? route.fromLocationID
                let end = namesByID[route.toLocationID] ?? route.toLocationID
                let owner = route.placedLink.flatMap { playersByID[$0.ownerID] }
                return GameMapAccessibilityTarget(
                    id: route.id,
                    label: MapRouteAccessibility.label(
                        route: route, startName: start, endName: end,
                        currentEra: currentEra, ownerName: owner
                    )
                )
            }
        let merchants = state.locations.flatMap { location in
            location.merchantPlacements
                .filter { highlightedIDs.contains($0.slotID) }
                .map { merchant in
                    GameMapAccessibilityTarget(
                        id: merchant.slotID,
                        label: MapMerchantAccessibility.label(
                            locationName: location.name,
                            merchant: merchant
                        )
                    )
                }
        }
        let industries = state.locations.flatMap { location in
            location.industryPlacements.enumerated().compactMap {
                index, placement -> GameMapAccessibilityTarget? in
                guard highlightedIDs.contains(placement.placementID) else { return nil }
                let owner = playersByID[placement.ownerID] ?? placement.ownerID
                return GameMapAccessibilityTarget(
                    id: placement.placementID,
                    label: MapIndustryAccessibility.label(
                        locationName: location.name,
                        ordinal: index + 1,
                        placement: placement,
                        ownerName: owner
                    )
                )
            }
        }
        return locations + routes + industries + merchants
    }
}

@MainActor
struct GameMapView: View {
    let state: DemoMatchState
    let highlightedIDs: Set<String>
    let onTargetTap: (String) -> Void
    let onBackgroundTap: () -> Void
    let accessibilityEnabled: Bool
    let legendInsets: MapLegendInsets
    let viewportInsets: MapViewportInsets

    @State private var scene: GameMapScene
    @State private var appliedCameraTranslation: CGPoint = .zero
    @State private var committedTranslation: CGPoint = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var isDragging = false
    @State private var isPinching = false
    @State private var suppressNextDragEnd = false
    @State private var pinchStartTranslation: CGPoint?
    @State private var pinchAnchor: CGPoint?
    @State private var committedScale = MapViewportMetrics.minimumZoom
    @State private var gestureScale: CGFloat = 1
    @State private var panSignpost: PrototypeSignpost.Interval?
    @State private var zoomSignpost: PrototypeSignpost.Interval?
    @State private var tapRoutingState = MapTapRoutingState()
    @State private var isTapResolutionScheduled = false

    init(
        state: DemoMatchState,
        highlightedIDs: Set<String>,
        onTargetTap: @escaping (String) -> Void,
        onBackgroundTap: @escaping () -> Void = {},
        accessibilityEnabled: Bool = true,
        legendInsets: MapLegendInsets = .zero,
        viewportInsets: MapViewportInsets = .zero
    ) {
        self.state = state
        self.highlightedIDs = highlightedIDs
        self.onTargetTap = onTargetTap
        self.onBackgroundTap = onBackgroundTap
        self.accessibilityEnabled = accessibilityEnabled
        self.legendInsets = legendInsets
        self.viewportInsets = viewportInsets
        _scene = State(initialValue: GameMapScene())
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                SpriteView(scene: scene)
                    .contentShape(Rectangle())
                    .simultaneousGesture(dragGesture)
                    .simultaneousGesture(magnifyGesture)
                    .simultaneousGesture(tapGesture)
                    .onAppear { synchronizeScene(viewportSize: proxy.size) }
                    .onChange(of: proxy.size) { _, newSize in
                        let appliedTranslation = scene.updateViewport(
                            size: newSize,
                            insets: viewportInsets
                        )
                        appliedCameraTranslation = appliedTranslation
                        if !isDragging, !isPinching {
                            committedTranslation = appliedTranslation
                        }
                        updateCamera()
                    }
                    .onChange(of: viewportInsets) { _, newInsets in
                        let appliedTranslation = scene.updateViewport(
                            size: proxy.size,
                            insets: newInsets
                        )
                        appliedCameraTranslation = appliedTranslation
                        if !isDragging, !isPinching {
                            committedTranslation = appliedTranslation
                        }
                        updateCamera()
                    }
                    .onChange(of: state) { _, _ in synchronizeScene(viewportSize: proxy.size) }
                    .onChange(of: highlightedIDs) { _, _ in synchronizeScene(viewportSize: proxy.size) }

                MapRouteLegend()
                    .padding(.top, 8 + legendInsets.top)
                    .padding(.trailing, 8 + legendInsets.trailing)
            }
            .accessibilityRepresentation {
                if accessibilityEnabled {
                    ZStack {
                        Color.clear
                            .accessibilityElement()
                            .accessibilityLabel("工业地图")
                            .accessibilityValue(String(format: "缩放 %.2f 倍", currentSemanticZoom))
                            .accessibilityIdentifier("match.map")

                        VStack {
                            Text("路线图例：运河专用，铁路专用，两时代通用")
                                .accessibilityIdentifier("map.routeLegend")
                            ForEach(accessibleTargets, id: \.id) { target in
                                Button(target.label) {
                                    activateAccessibilityTarget(target.id)
                                }
                                    .accessibilityIdentifier("map.target.\(target.id)")
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("snapshot.ready")
                } else {
                    EmptyView()
                }
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isPinching else {
                    dragTranslation = .zero
                    return
                }
                suppressNextDragEnd = false
                if panSignpost == nil {
                    panSignpost = PrototypeSignpost.begin(.mapPanZoom)
                }
                isDragging = true
                dragTranslation = value.translation
                updateCamera()
            }
            .onEnded { value in
                guard !isPinching, !suppressNextDragEnd else {
                    suppressNextDragEnd = false
                    dragTranslation = .zero
                    isDragging = false
                    panSignpost?.end()
                    panSignpost = nil
                    return
                }
                let sceneTranslation = scene.viewportMetrics.sceneTranslation(forDrag: value.translation)
                let proposal = CGPoint(
                    x: committedTranslation.x + sceneTranslation.x,
                    y: committedTranslation.y + sceneTranslation.y
                )
                committedTranslation = updateCamera(
                    scale: clampedScale(committedScale * gestureScale),
                    translation: proposal
                )
                dragTranslation = .zero
                isDragging = false
                panSignpost?.end()
                panSignpost = nil
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchAnchor == nil {
                    pinchAnchor = value.startLocation
                    pinchStartTranslation = appliedCameraTranslation
                    dragTranslation = .zero
                    isDragging = false
                    isPinching = true
                    suppressNextDragEnd = true
                }
                if zoomSignpost == nil {
                    zoomSignpost = PrototypeSignpost.begin(.mapPanZoom)
                }
                gestureScale = value.magnification
                updateCamera()
            }
            .onEnded { value in
                gestureScale = value.magnification
                updateCamera()
                committedScale = currentSemanticZoom
                committedTranslation = appliedCameraTranslation
                gestureScale = 1
                pinchStartTranslation = nil
                pinchAnchor = nil
                isPinching = false
                updateCamera()
                zoomSignpost?.end()
                zoomSignpost = nil
            }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let route = targetID(atViewPoint: value.location)
                    .map(GameMapTapRoute.target) ?? .background
                tapRoutingState.recordPhysicalTap(route)
                scheduleTapResolution()
            }
    }

    private func targetID(atViewPoint point: CGPoint) -> String? {
        guard scene.view != nil else { return nil }
        return scene.targetID(atScenePoint: scene.convertPoint(fromView: point))
    }

    private func activateAccessibilityTarget(_ id: String) {
        tapRoutingState.recordAccessibilityActivation()
        scheduleTapResolution()
        onTargetTap(id)
    }

    private func scheduleTapResolution() {
        guard isTapResolutionScheduled == false else { return }
        isTapResolutionScheduled = true
        Task { @MainActor in
            await Task.yield()
            await Task.yield()
            let route = tapRoutingState.resolve()
            isTapResolutionScheduled = false
            switch route {
            case .target(let id):
                onTargetTap(id)
            case .background:
                onBackgroundTap()
            case nil:
                break
            }
        }
    }

    private func synchronizeScene(viewportSize: CGSize) {
        scene.onTargetTap = onTargetTap
        scene.configure(state: state, highlightedIDs: highlightedIDs)
        let appliedTranslation = scene.updateViewport(
            size: viewportSize,
            insets: viewportInsets
        )
        appliedCameraTranslation = appliedTranslation
        if !isDragging, !isPinching {
            committedTranslation = appliedTranslation
        }
        updateCamera()
    }

    private func updateCamera() {
        let translation: CGPoint
        if let pinchStartTranslation, let pinchAnchor {
            translation = MapPinchZoom.projection(
                startingZoom: committedScale,
                magnification: gestureScale,
                anchorInView: pinchAnchor,
                startingTranslation: pinchStartTranslation,
                metrics: scene.viewportMetrics
            ).translation
        } else {
            let currentDrag = scene.viewportMetrics.sceneTranslation(forDrag: dragTranslation)
            translation = CGPoint(
                x: committedTranslation.x + currentDrag.x,
                y: committedTranslation.y + currentDrag.y
            )
        }
        let appliedTranslation = updateCamera(
            scale: currentSemanticZoom,
            translation: translation
        )
        if !isDragging, !isPinching {
            committedTranslation = appliedTranslation
        }
    }

    @discardableResult
    private func updateCamera(scale: CGFloat, translation: CGPoint) -> CGPoint {
        let appliedTranslation = scene.updateCamera(scale: scale, translation: translation)
        appliedCameraTranslation = appliedTranslation
        return appliedTranslation
    }

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, MapViewportMetrics.minimumZoom), MapViewportMetrics.maximumZoom)
    }

    private var currentSemanticZoom: CGFloat {
        clampedScale(committedScale * gestureScale)
    }

    private var accessibleTargets: [GameMapAccessibilityTarget] {
        GameMapAccessibility.targets(state: state, highlightedIDs: highlightedIDs)
    }
}

#if DEBUG
#Preview {
    GameMapView(
        state: DemoFixture.match(playerCount: 4),
        highlightedIDs: ["birmingham", "birmingham-coventry"],
        onTargetTap: { _ in }
    )
}
#endif
