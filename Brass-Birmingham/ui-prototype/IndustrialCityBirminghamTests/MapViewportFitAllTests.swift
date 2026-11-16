import CoreGraphics
import Testing
@testable import IndustrialCityBirmingham

@MainActor
struct MapViewportFitAllTests {
    private static let phoneHandInsets = MapViewportInsets(
        top: 76, leading: 44, bottom: 92, trailing: 44
    )

    @Test(arguments: [
        CGSize(width: 390, height: 844),
        CGSize(width: 852, height: 393),
        CGSize(width: 1_194, height: 834),
        CGSize(width: 2_732, height: 2_048)
    ])
    func zoomFloorRevealsEntireBoardWithoutPanning(viewport: CGSize) {
        let metrics = MapViewportMetrics(
            logicalSize: GameMapScene.logicalSize,
            viewportSize: viewport,
            semanticZoom: MapViewportMetrics.autoFitZoom,
            viewportInsets: Self.phoneHandInsets
        )

        #expect(metrics.semanticZoom == metrics.zoomFloor)
        #expect(metrics.zoomFloor <= MapViewportMetrics.aspectFillZoom)

        let visible = metrics.unobscuredSceneRect(
            cameraCenter: metrics.clampedCameraCenter(.zero)
        )
        #expect(visible.minX <= 0.0001)
        #expect(visible.minY <= 0.0001)
        #expect(visible.maxX >= GameMapScene.logicalSize.width - 0.0001)
        #expect(visible.maxY >= GameMapScene.logicalSize.height - 0.0001)

        // 整幅可见时,极端平移提议被钳制回“未遮挡可视区居中于版图中心”
        // (相机坐标本身允许因不对称边距而偏移)。
        let clampedVisible = metrics.unobscuredSceneRect(
            cameraCenter: metrics.clampedCameraCenter(CGPoint(x: 10_000, y: -10_000))
        )
        #expect(abs(clampedVisible.midX - GameMapScene.logicalSize.width / 2) < 0.001)
        #expect(abs(clampedVisible.midY - GameMapScene.logicalSize.height / 2) < 0.001)
    }

    /// 对局真实边距(手机横屏,852 宽去顶栏后 349 高):两侧栏+安全区+名牌净空,
    /// 底部手牌带 + 常驻浮层 ≈ 180pt。未遮挡带只剩 ~544×169pt。
    private static let phoneMatchInsets = MapViewportInsets(
        top: 0, leading: 103, bottom: 180, trailing: 205
    )

    /// 进场初始档应"整幅铺满整个视口"(浮层浮在图上),而不是 zoomFloor 那档
    /// 把版图挤进未遮挡窄带——后者在手机横屏上只有 ~170pt 高,版图缩成一小团。
    @Test(arguments: [
        CGSize(width: 852, height: 349),
        CGSize(width: 390, height: 800)
    ])
    func overviewDefaultFillsEntireViewportInsteadOfOverlayBand(viewport: CGSize) {
        let floorMetrics = MapViewportMetrics(
            logicalSize: GameMapScene.logicalSize,
            viewportSize: viewport,
            semanticZoom: MapViewportMetrics.autoFitZoom,
            viewportInsets: Self.phoneMatchInsets
        )
        let overviewMetrics = MapViewportMetrics(
            logicalSize: GameMapScene.logicalSize,
            viewportSize: viewport,
            semanticZoom: floorMetrics.overviewZoom,
            viewportInsets: Self.phoneMatchInsets
        )

        func boardSizeOnScreen(_ metrics: MapViewportMetrics) -> CGSize {
            let pointsPerSceneUnit = 1 / metrics.visibleSceneSize.width * metrics.viewportSize.width
            return CGSize(
                width: GameMapScene.logicalSize.width * pointsPerSceneUnit,
                height: GameMapScene.logicalSize.height * pointsPerSceneUnit
            )
        }

        // 问题现场:下限档的版图被压进未遮挡带,横竖屏都只剩很小一团。
        #expect(boardSizeOnScreen(floorMetrics).height < 0.6 * viewport.height)
        // 初始档:整幅恰好铺满整个视口的受限边(竖屏铺宽、横屏铺高),
        // 另一边不裁切版图。
        #expect(overviewMetrics.overviewZoom > floorMetrics.zoomFloor)
        let overviewBoard = boardSizeOnScreen(overviewMetrics)
        #expect(
            max(overviewBoard.width / viewport.width, overviewBoard.height / viewport.height)
                >= 0.99
        )
        #expect(overviewMetrics.visibleSceneSize.width >= GameMapScene.logicalSize.width - 0.0001)
        #expect(overviewMetrics.visibleSceneSize.height >= GameMapScene.logicalSize.height - 0.0001)
    }

    /// 无浮层边距的视图(demo/预览):初始档与下限档重合,行为不因本次改动改变。
    @Test func overviewZoomCoincidesWithFloorWithoutInsets() {
        let metrics = MapViewportMetrics(
            logicalSize: GameMapScene.logicalSize,
            viewportSize: CGSize(width: 852, height: 393),
            semanticZoom: MapViewportMetrics.autoFitZoom
        )

        #expect(abs(metrics.overviewZoom - metrics.zoomFloor) < 0.0001)
    }

    @Test func portraitFloorDropsBelowAspectFillAnchor() {
        let metrics = MapViewportMetrics(
            logicalSize: GameMapScene.logicalSize,
            viewportSize: CGSize(width: 390, height: 844),
            semanticZoom: MapViewportMetrics.autoFitZoom,
            viewportInsets: Self.phoneHandInsets
        )

        #expect(metrics.zoomFloor < MapViewportMetrics.aspectFillZoom)
        #expect(metrics.semanticZoom == metrics.zoomFloor)
    }

    @Test func freshSceneStartsAtFitAllOverview() {
        let scene = GameMapScene()

        #expect(scene.viewportMetrics.semanticZoom == scene.viewportMetrics.zoomFloor)
    }

    @Test func rotationKeepsAutoFitPinnedToTheNewFloor() {
        let scene = GameMapScene()
        scene.updateViewport(
            size: CGSize(width: 390, height: 844),
            insets: Self.phoneHandInsets
        )
        scene.updateCamera(
            scale: MapViewportMetrics.autoFitZoom,
            translation: .zero
        )
        #expect(scene.viewportMetrics.semanticZoom == scene.viewportMetrics.zoomFloor)

        scene.updateViewport(
            size: CGSize(width: 844, height: 390),
            insets: Self.phoneHandInsets
        )
        #expect(scene.viewportMetrics.semanticZoom == scene.viewportMetrics.zoomFloor)
        #expect(scene.viewportMetrics.visibleSceneSize.width >= GameMapScene.logicalSize.width - 0.0001)
        #expect(scene.viewportMetrics.visibleSceneSize.height >= GameMapScene.logicalSize.height - 0.0001)
    }

    @Test func autoFitSentinelPinchesUpFromFloor() {
        let metrics = MapViewportMetrics(
            logicalSize: GameMapScene.logicalSize,
            viewportSize: CGSize(width: 390, height: 844),
            semanticZoom: 1,
            viewportInsets: Self.phoneHandInsets
        )
        let anchor = CGPoint(x: 195, y: 422)

        let projection = MapPinchZoom.projection(
            startingZoom: MapViewportMetrics.autoFitZoom,
            magnification: 2.5,
            anchorInView: anchor,
            startingTranslation: .zero,
            metrics: metrics
        )

        #expect(abs(projection.semanticZoom - metrics.zoomFloor * 2.5) < 0.0001)
    }
}
