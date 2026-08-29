import Testing
import UIKit
@testable import IndustrialCityBirmingham

@MainActor
struct IndustrialMatchChromeTests {
    @Test(arguments: [
        (IndustryKind.cotton, IndustrialMatchAsset.cotton, "industry-cotton-medallion"),
        (.manufacturer, .manufacturer, "industry-manufacturer-medallion"),
        (.pottery, .pottery, "industry-pottery-medallion"),
        (.coal, .coal, "industry-coal-medallion"),
        (.iron, .iron, "industry-iron-medallion"),
        (.brewery, .brewery, "industry-brewery-medallion")
    ])
    func everyIndustryHasItsExpectedOriginalMedallion(
        kind: IndustryKind,
        asset: IndustrialMatchAsset,
        name: String
    ) {
        let medallion = IndustrialMatchAsset.industryMedallion(kind)

        #expect(medallion == asset)
        #expect(medallion.name == name)
    }

    @Test func requiredAssetsContainTheExactIndustrialContract() {
        let expectedAssets: [IndustrialMatchAsset] = [
            .ironHorizontal,
            .ironVertical,
            .woodFill,
            .parchmentLabel,
            .cardTexture,
            .brassCorner,
            .cotton,
            .manufacturer,
            .pottery,
            .coal,
            .iron,
            .brewery
        ]
        let expectedNames = [
            "match-iron-horizontal",
            "match-iron-vertical",
            "match-wood-fill",
            "match-parchment-label",
            "match-card-texture",
            "match-brass-corner",
            "industry-cotton-medallion",
            "industry-manufacturer-medallion",
            "industry-pottery-medallion",
            "industry-coal-medallion",
            "industry-iron-medallion",
            "industry-brewery-medallion"
        ]

        #expect(IndustrialMatchAsset.required.count == 12)
        #expect(IndustrialMatchAsset.required == expectedAssets)
        #expect(IndustrialMatchAsset.required.map(\.name) == expectedNames)
    }

    @Test(arguments: IndustrialMatchAsset.required)
    func everyRequiredTextureExists(_ asset: IndustrialMatchAsset) {
        #expect(UIImage(named: asset.name) != nil)
    }

    @Test func legalAndUnavailableStatesRemainReadableOnCoal() {
        #expect(BrassColor.legalGreen.contrastRatio(against: .coal) >= 3.0)
        #expect(BrassColor.unavailableRed.contrastRatio(against: .coal) >= 3.0)
    }

}
