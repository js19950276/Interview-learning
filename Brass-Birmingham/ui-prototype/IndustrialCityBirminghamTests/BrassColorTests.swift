import CoreGraphics
import SwiftUI
import Testing
@testable import IndustrialCityBirmingham

@MainActor
struct BrassColorTests {
    @Test func paperOnCoalMeetsNormalTextContrast() {
        #expect(BrassColor.paper.contrastRatio(against: .coal) >= 4.5)
    }

    @Test func brassOnCoalMeetsLargeTextContrast() {
        #expect(BrassColor.brass.contrastRatio(against: .coal) >= 3.0)
    }

    @Test func pressedBrassOnCoalMeetsNormalTextContrast() {
        #expect(BrassColor.pressedBrass.contrastRatio(against: .coal) >= 4.5)
    }

    @Test func industrialPaperAndBrassRemainReadableOnWood() {
        #expect(BrassColor.paper.contrastRatio(against: .darkWood) >= 4.5)
        #expect(BrassColor.brass.contrastRatio(against: .darkWood) >= 3.0)
    }

    @Test func industrialTokensUseExactRGBComponents() {
        expectColor(BrassColor.darkWood, equalsHex: 0x30251D)
        expectColor(BrassColor.forgedIron, equalsHex: 0x2A2D2D)
        expectColor(BrassColor.parchmentShadow, equalsHex: 0xA98D62)
        expectColor(BrassColor.legalGreen, equalsHex: 0x8CCB6B)
        expectColor(BrassColor.unavailableRed, equalsHex: 0xC66A59)
    }

    @Test func spacingTokensStayOnFourPointGrid() {
        #expect(BrassSpacing.all.allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 })
    }

    @Test func typographyTokensUseSemanticTextStyles() {
        #expect(BrassTypography.displayToken.textStyle == .largeTitle)
        #expect(BrassTypography.titleToken.textStyle == .title2)
        #expect(BrassTypography.bodyToken.textStyle == .subheadline)
        #expect(BrassTypography.labelToken.textStyle == .caption)
        #expect(BrassTypography.numberToken.textStyle == .subheadline)
    }

    private func expectColor(_ color: BrassColor, equalsHex hex: Int, tolerance: Double = 0.000_001) {
        #expect(abs(color.red - component(hex, shift: 16)) <= tolerance)
        #expect(abs(color.green - component(hex, shift: 8)) <= tolerance)
        #expect(abs(color.blue - component(hex, shift: 0)) <= tolerance)
    }

    private func component(_ hex: Int, shift: Int) -> Double {
        Double((hex >> shift) & 0xFF) / 255
    }
}
