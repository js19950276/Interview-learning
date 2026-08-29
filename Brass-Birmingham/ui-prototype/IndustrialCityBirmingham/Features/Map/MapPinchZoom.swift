import CoreGraphics

struct MapPinchZoomProjection: Equatable, Sendable {
    let semanticZoom: CGFloat
    let translation: CGPoint
}

enum MapPinchZoom {
    static func projection(
        startingZoom: CGFloat,
        magnification: CGFloat,
        anchorInView: CGPoint,
        startingTranslation: CGPoint,
        metrics: MapViewportMetrics
    ) -> MapPinchZoomProjection {
        let startMetrics = MapViewportMetrics(
            logicalSize: metrics.logicalSize,
            viewportSize: metrics.viewportSize,
            semanticZoom: startingZoom,
            viewportInsets: metrics.viewportInsets
        )
        let targetZoom = min(
            max(
                startMetrics.semanticZoom * magnification,
                MapViewportMetrics.minimumZoom
            ),
            MapViewportMetrics.maximumZoom
        )
        let targetMetrics = MapViewportMetrics(
            logicalSize: metrics.logicalSize,
            viewportSize: metrics.viewportSize,
            semanticZoom: targetZoom,
            viewportInsets: metrics.viewportInsets
        )
        let viewportCenter = CGPoint(
            x: metrics.viewportSize.width / 2,
            y: metrics.viewportSize.height / 2
        )
        let sceneUnitsDelta = startMetrics.sceneUnitsPerPoint
            - targetMetrics.sceneUnitsPerPoint

        return MapPinchZoomProjection(
            semanticZoom: targetZoom,
            translation: CGPoint(
                x: startingTranslation.x
                    + (anchorInView.x - viewportCenter.x) * sceneUnitsDelta,
                y: startingTranslation.y
                    - (anchorInView.y - viewportCenter.y) * sceneUnitsDelta
            )
        )
    }
}
