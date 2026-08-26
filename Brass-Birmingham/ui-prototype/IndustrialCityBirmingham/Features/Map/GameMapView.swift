import SpriteKit
import SwiftUI

nonisolated struct MapLegendInsets: Equatable, Sendable {
    static let zero = MapLegendInsets(top: 0, trailing: 0)

    let top: CGFloat
    let trailing: CGFloat
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
    @State private var committedTranslation: CGPoint = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var isDragging = false
    @State private var committedScale = MapViewportMetrics.minimumZoom
    @State private var gestureScale: CGFloat = 1
    @State private var panSignpost: PrototypeSignpost.Interval?
    @State private var zoomSignpost: PrototypeSignpost.Interval?

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
                        if !isDragging {
                            committedTranslation = appliedTranslation
                        }
                        updateCamera()
                    }
                    .onChange(of: viewportInsets) { _, newInsets in
                        let appliedTranslation = scene.updateViewport(
                            size: proxy.size,
                            insets: newInsets
                        )
                        if !isDragging {
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
                            .accessibilityIdentifier("match.map")

                        VStack {
                            Text("路线图例：运河专用，铁路专用，两时代通用")
                                .accessibilityIdentifier("map.routeLegend")
                            ForEach(accessibleTargets, id: \.id) { target in
                                Button(target.label) { onTargetTap(target.id) }
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
                if panSignpost == nil {
                    panSignpost = PrototypeSignpost.begin(.mapPanZoom)
                }
                isDragging = true
                dragTranslation = value.translation
                updateCamera()
            }
            .onEnded { value in
                let sceneTranslation = scene.viewportMetrics.sceneTranslation(forDrag: value.translation)
                let proposal = CGPoint(
                    x: committedTranslation.x + sceneTranslation.x,
                    y: committedTranslation.y + sceneTranslation.y
                )
                committedTranslation = scene.updateCamera(
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
                if zoomSignpost == nil {
                    zoomSignpost = PrototypeSignpost.begin(.mapPanZoom)
                }
                gestureScale = value.magnification
                updateCamera()
            }
            .onEnded { value in
                committedScale = clampedScale(committedScale * value.magnification)
                gestureScale = 1
                updateCamera()
                zoomSignpost?.end()
                zoomSignpost = nil
            }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                scene.onTargetTap = onTargetTap
                if !scene.activateTarget(atViewPoint: value.location) {
                    onBackgroundTap()
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
        if !isDragging {
            committedTranslation = appliedTranslation
        }
        updateCamera()
    }

    private func updateCamera() {
        let currentDrag = scene.viewportMetrics.sceneTranslation(forDrag: dragTranslation)
        let translation = CGPoint(
            x: committedTranslation.x + currentDrag.x,
            y: committedTranslation.y + currentDrag.y
        )
        let appliedTranslation = scene.updateCamera(
            scale: clampedScale(committedScale * gestureScale),
            translation: translation
        )
        if !isDragging {
            committedTranslation = appliedTranslation
        }
    }

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, MapViewportMetrics.minimumZoom), MapViewportMetrics.maximumZoom)
    }

    private var accessibleTargets: [(id: String, label: String)] {
        let locations = state.locations
            .filter { highlightedIDs.contains($0.id) }
            .map { (id: $0.id, label: $0.name) }
        let namesByID = Dictionary(uniqueKeysWithValues: state.locations.map { ($0.id, $0.name) })
        let playersByID = Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, $0.name) })
        let currentEra = MapRouteEraStyle.currentEra(from: state.era)
        let routes = state.routes
            .filter { highlightedIDs.contains($0.id) }
            .map { route in
                let start = namesByID[route.fromLocationID] ?? route.fromLocationID
                let end = namesByID[route.toLocationID] ?? route.toLocationID
                let owner = route.placedLink.flatMap { playersByID[$0.ownerID] }
                return (
                    id: route.id,
                    label: MapRouteAccessibility.label(
                        route: route, startName: start, endName: end,
                        currentEra: currentEra, ownerName: owner
                    )
                )
            }
        return locations + routes
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
