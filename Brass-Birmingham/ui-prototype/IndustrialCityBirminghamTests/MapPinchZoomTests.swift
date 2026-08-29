import CoreGraphics
import Testing
@testable import IndustrialCityBirmingham

@MainActor
struct MapPinchZoomTests {
    @Test func offCenterAnchorKeepsTheSameScenePointAfterZooming() {
        let metrics = MapViewportMetrics(
            logicalSize: GameMapScene.logicalSize,
            viewportSize: CGSize(width: 852, height: 393),
            semanticZoom: 1,
            viewportInsets: MapViewportInsets(top: 18, leading: 0, bottom: 96, trailing: 44)
        )
        let anchor = CGPoint(x: 612, y: 278)
        let startingTranslation = CGPoint(x: 148, y: -76)

        let projection = MapPinchZoom.projection(
            startingZoom: 1,
            magnification: 1.8,
            anchorInView: anchor,
            startingTranslation: startingTranslation,
            metrics: metrics
        )

        let startScenePoint = scenePoint(
            under: anchor,
            translation: startingTranslation,
            metrics: metrics
        )
        let targetScenePoint = scenePoint(
            under: anchor,
            translation: projection.translation,
            metrics: MapViewportMetrics(
                logicalSize: metrics.logicalSize,
                viewportSize: metrics.viewportSize,
                semanticZoom: projection.semanticZoom,
                viewportInsets: metrics.viewportInsets
            )
        )

        #expect(abs(projection.semanticZoom - 1.8) < 0.0001)
        #expect(abs(targetScenePoint.x - startScenePoint.x) < 0.0001)
        #expect(abs(targetScenePoint.y - startScenePoint.y) < 0.0001)
    }

    @Test(arguments: [0.01, 100.0])
    func magnificationClampsToSemanticZoomBounds(_ magnification: Double) {
        let anchor = CGPoint(x: 612, y: 278)
        let startingTranslation = CGPoint(x: 148, y: -76)
        let metrics = MapViewportMetrics(
            logicalSize: GameMapScene.logicalSize,
            viewportSize: CGSize(width: 852, height: 393),
            semanticZoom: 1,
            viewportInsets: MapViewportInsets(top: 18, leading: 0, bottom: 96, trailing: 44)
        )
        let projection = MapPinchZoom.projection(
            startingZoom: 1,
            magnification: CGFloat(magnification),
            anchorInView: anchor,
            startingTranslation: startingTranslation,
            metrics: metrics
        )
        let expectedZoom = magnification < 1
            ? MapViewportMetrics.minimumZoom
            : MapViewportMetrics.maximumZoom
        let startScenePoint = scenePoint(
            under: anchor,
            translation: startingTranslation,
            metrics: metrics
        )
        let targetScenePoint = scenePoint(
            under: anchor,
            translation: projection.translation,
            metrics: MapViewportMetrics(
                logicalSize: metrics.logicalSize,
                viewportSize: metrics.viewportSize,
                semanticZoom: projection.semanticZoom,
                viewportInsets: metrics.viewportInsets
            )
        )

        #expect(abs(projection.semanticZoom - expectedZoom) < 0.0001)
        #expect(abs(targetScenePoint.x - startScenePoint.x) < 0.0001)
        #expect(abs(targetScenePoint.y - startScenePoint.y) < 0.0001)
    }

    private func scenePoint(
        under anchorInView: CGPoint,
        translation: CGPoint,
        metrics: MapViewportMetrics
    ) -> CGPoint {
        let cameraCenter = CGPoint(
            x: metrics.logicalSize.width / 2 + translation.x,
            y: metrics.logicalSize.height / 2 + translation.y
        )
        let viewportCenter = CGPoint(
            x: metrics.viewportSize.width / 2,
            y: metrics.viewportSize.height / 2
        )
        return CGPoint(
            x: cameraCenter.x + (anchorInView.x - viewportCenter.x) * metrics.sceneUnitsPerPoint,
            y: cameraCenter.y - (anchorInView.y - viewportCenter.y) * metrics.sceneUnitsPerPoint
        )
    }
}
