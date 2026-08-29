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
        #expect(metrics.headerHeight == 44)
        #expect(metrics.mapTopInset == 44)
    }

    @Test(arguments: [1024.0, 1194.0, 1366.0])
    func tabletUsesFullRails(_ width: Double) {
        let metrics = MatchLayoutMetrics(viewport: CGSize(width: width, height: 834))
        #expect(metrics.formFactor == .tablet)
        #expect(metrics.leftRailWidth == 184)
        #expect(metrics.rightRailWidth == 176)
        #expect(metrics.marketPlacement == .underPlayerRail)
        #expect(metrics.headerHeight == 48)
        #expect(metrics.mapTopInset == 48)
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
        #expect(phone.mapLegendInsets.top == phone.mapTopInset)
        #expect(phone.mapLegendInsets.trailing == 44)

        let tablet = MatchLayoutMetrics(viewport: CGSize(width: 1_194, height: 834))
        #expect(tablet.mapLegendInsets.top == tablet.mapTopInset)
        #expect(tablet.mapLegendInsets.trailing == 176)
    }

    @Test func mapLegendInsetsWithinPaddedViewportDoNotDoubleCountHeader() {
        let phone = MatchLayoutMetrics(
            viewport: CGSize(width: 852, height: 393),
            safeAreaTrailing: 59
        )
        #expect(phone.mapLegendInsetsWithinPaddedViewport.top == 0)
        #expect(phone.mapLegendInsetsWithinPaddedViewport.trailing == 103)

        let tablet = MatchLayoutMetrics(viewport: CGSize(width: 1_194, height: 834))
        #expect(tablet.mapLegendInsetsWithinPaddedViewport.top == 0)
        #expect(tablet.mapLegendInsetsWithinPaddedViewport.trailing == 176)
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

    @Test func steamInspiredChromeKeepsMapDominant() {
        let phone = MatchLayoutMetrics(viewport: CGSize(width: 852, height: 393))
        #expect(phone.headerHeight == 44)
        #expect(phone.mapTopInset == 44)
        #expect(phone.leftRailWidth == 44)
        #expect(phone.rightRailWidth == 44)
        #expect(phone.handHeight == 92)
        #expect(phone.mapViewportInsets.top == 0)
        #expect(phone.mapLegendInsets.top == phone.mapTopInset)

        let tablet = MatchLayoutMetrics(viewport: CGSize(width: 1_194, height: 834))
        #expect(tablet.headerHeight == 48)
        #expect(tablet.mapTopInset == 48)
        #expect(tablet.leftRailWidth == 184)
        #expect(tablet.rightRailWidth == 176)
        #expect(tablet.handHeight == 132)
        #expect(tablet.mapViewportInsets == .zero)
        #expect(tablet.mapLegendInsets.top == tablet.mapTopInset)
    }
}
