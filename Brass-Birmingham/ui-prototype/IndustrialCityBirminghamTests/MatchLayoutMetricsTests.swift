import Testing
import CoreGraphics
@testable import IndustrialCityBirmingham

struct MatchLayoutMetricsTests {
    @Test(arguments: [667.0, 852.0, 932.0])
    func phoneUsesMiniRails(_ width: Double) {
        let metrics = MatchLayoutMetrics(viewport: CGSize(width: width, height: 393))
        #expect(metrics.formFactor == .phone)
        #expect(metrics.leftRailWidth == 44)
        #expect(metrics.rightRailWidth == 44)
        #expect(metrics.marketPlacement == .bottomLeftCompact)
        #expect(metrics.mapTopInset == 76)
    }

    @Test(arguments: [1024.0, 1194.0, 1366.0])
    func tabletUsesFullRails(_ width: Double) {
        let metrics = MatchLayoutMetrics(viewport: CGSize(width: width, height: 834))
        #expect(metrics.formFactor == .tablet)
        #expect(metrics.leftRailWidth == 220)
        #expect(metrics.rightRailWidth == 210)
        #expect(metrics.marketPlacement == .underPlayerRail)
        #expect(metrics.mapTopInset == 58)
    }

    @Test(arguments: [667.0, 852.0, 932.0, 999.0])
    func phoneUsesNinetyTwoPointHand(_ width: Double) {
        let metrics = MatchLayoutMetrics(viewport: CGSize(width: width, height: 393))
        #expect(metrics.handHeight == 92)
    }

    @Test(arguments: [1000.0, 1024.0, 1194.0, 1366.0])
    func tabletUsesOneHundredThirtyTwoPointHand(_ width: Double) {
        let metrics = MatchLayoutMetrics(viewport: CGSize(width: width, height: 834))
        #expect(metrics.handHeight == 132)
    }

    @Test func mapLegendInsetsClearHeaderAndRightRail() {
        let phone = MatchLayoutMetrics(viewport: CGSize(width: 852, height: 393))
        #expect(phone.mapLegendInsets.top == 76)
        #expect(phone.mapLegendInsets.trailing == 44)

        let tablet = MatchLayoutMetrics(viewport: CGSize(width: 1_194, height: 834))
        #expect(tablet.mapLegendInsets.top == 58)
        #expect(tablet.mapLegendInsets.trailing == 210)
    }

    @Test func mapLegendInsetsAlsoClearLandscapeSafeArea() {
        let phone = MatchLayoutMetrics(
            viewport: CGSize(width: 852, height: 393),
            safeAreaTrailing: 59
        )

        #expect(phone.mapLegendInsets.trailing == 103)
    }

    @Test func phoneMapViewportInsetsClearHandAndMiniRailsWithoutDoubleCountingHeader() {
        let metrics = MatchLayoutMetrics(
            viewport: CGSize(width: 852, height: 393),
            safeAreaTrailing: 59
        )

        #expect(metrics.mapViewportInsets == MapViewportInsets(
            top: 0,
            leading: 44,
            bottom: 92,
            trailing: 103
        ))
    }

    @Test func tabletKeepsLegacyZeroMapViewportInsets() {
        let metrics = MatchLayoutMetrics(
            viewport: CGSize(width: 1_194, height: 834),
            safeAreaTrailing: 24
        )

        #expect(metrics.mapViewportInsets == .zero)
    }
}
