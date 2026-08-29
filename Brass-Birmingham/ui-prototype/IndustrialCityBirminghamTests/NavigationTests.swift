import Testing
import UIKit
@testable import IndustrialCityBirmingham

struct NavigationTests {
    @MainActor
    @Test func matchRouteRequiresLandscape() {
        #expect(AppRoute.match(playerCount: 4).orientationMask == .landscape)
    }

    @MainActor
    @Test func nonMatchRoutesAllowAllButUpsideDown() {
        #expect(AppRoute.home.orientationMask == .allButUpsideDown)
        #expect(AppRoute.settings.orientationMask == .allButUpsideDown)
    }

    @MainActor
    @Test func navigationPathDeterminesOrientation() {
        #expect(
            OrientationPolicy.mask(
                for: [.settings, .match(playerCount: 4)]
            ) == .landscape
        )
        #expect(
            OrientationPolicy.mask(for: [.settings]) == .allButUpsideDown
        )
        #expect(
            OrientationPolicy.mask(for: []) == .allButUpsideDown
        )
    }

    @MainActor
    @Test func orientationRegistryKeepsSceneStateIndependent() {
        var registry = OrientationMaskRegistry()

        registry.set(.landscape, for: "scene-a")

        #expect(registry.mask(for: "scene-a") == .landscape)
        #expect(registry.mask(for: "scene-b") == .allButUpsideDown)
        #expect(registry.mask(for: nil) == .allButUpsideDown)

        registry.reset("scene-a")

        #expect(registry.mask(for: "scene-a") == .allButUpsideDown)
    }

    @MainActor
    @Test func landscapeGeometryRequiresWideBounds() {
        #expect(
            OrientationGeometryPolicy.isSatisfied(
                mask: .landscape,
                interfaceOrientation: .landscapeRight,
                bounds: CGRect(x: 0, y: 0, width: 874, height: 402)
            )
        )
        #expect(
            !OrientationGeometryPolicy.isSatisfied(
                mask: .landscape,
                interfaceOrientation: .landscapeRight,
                bounds: CGRect(x: 0, y: 0, width: 402, height: 874)
            )
        )
    }

    @MainActor
    @Test func allButUpsideDownAcceptsCurrentValidGeometry() {
        #expect(
            OrientationGeometryPolicy.isSatisfied(
                mask: .allButUpsideDown,
                interfaceOrientation: .portrait,
                bounds: CGRect(x: 0, y: 0, width: 402, height: 874)
            )
        )
        #expect(
            OrientationGeometryPolicy.isSatisfied(
                mask: .allButUpsideDown,
                interfaceOrientation: .landscapeLeft,
                bounds: CGRect(x: 0, y: 0, width: 874, height: 402)
            )
        )
        #expect(
            !OrientationGeometryPolicy.isSatisfied(
                mask: .allButUpsideDown,
                interfaceOrientation: .portraitUpsideDown,
                bounds: CGRect(x: 0, y: 0, width: 402, height: 874)
            )
        )
    }

    @Test func matchEntryRequiresConfirmedLandscapeGeometry() {
        #expect(MatchEntryPolicy.canEnterMatch(geometryReady: true))
        #expect(!MatchEntryPolicy.canEnterMatch(geometryReady: false))
    }
}
