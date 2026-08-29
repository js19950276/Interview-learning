import Foundation
import Testing

struct ConfirmationPanelStyleTests {
    @Test func confirmationPanelUsesIndustrialChromeWithoutMaterialPlastic() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "IndustrialCityBirmingham/Features/Match/ConfirmationPanel.swift"),
            encoding: .utf8
        )

        #expect(source.contains(".padding(BrassSpacing.large)"))
        #expect(source.contains("Image(IndustrialMatchAsset.woodFill.name)"))
        #expect(source.contains("Image(IndustrialMatchAsset.ironHorizontal.name)"))
        #expect(source.contains(".frame(height: 8)"))
        #expect(source.contains(".clipShape(RoundedRectangle(cornerRadius: BrassRadius.panel"))
        #expect(source.contains(".stroke(BrassColor.brass.color"))
        #expect(source.contains(".allowsHitTesting(false)"))
        #expect(source.contains(".modifier(IndustrialPanelSurface(axis: .horizontal))") == false)
        #expect(source.contains(".brassPanel()") == false)
    }
}
