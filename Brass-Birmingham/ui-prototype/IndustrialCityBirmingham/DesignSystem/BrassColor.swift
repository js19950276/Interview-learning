import SwiftUI

struct BrassColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static let coal = BrassColor(hex: 0x1C2022)
    static let iron = BrassColor(hex: 0x7D5B45)
    static let brass = BrassColor(hex: 0xC49A50)
    static let pressedBrass = BrassColor(hex: 0xB98E47)
    static let fog = BrassColor(hex: 0x839093)
    static let paper = BrassColor(hex: 0xE7DDC8)
    static let danger = BrassColor(hex: 0xB44A3C)
    static let darkWood = BrassColor(hex: 0x30251D)
    static let forgedIron = BrassColor(hex: 0x2A2D2D)
    static let parchmentShadow = BrassColor(hex: 0xA98D62)
    static let legalGreen = BrassColor(hex: 0x8CCB6B)
    static let unavailableRed = BrassColor(hex: 0xC66A59)

    init(hex: Int) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    func contrastRatio(against other: BrassColor) -> Double {
        let brighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (brighter + 0.05) / (darker + 0.05)
    }

    private var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}
