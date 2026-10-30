import Foundation
import CoreImage
import AppKit
import PhoneProtocol

/// Renders the pairing QR as terminal text (Layer-① "one command" UX: the
/// CLI prints a scannable code; no menu bar app needed). White modules are
/// spaces, black modules are full blocks — scan with the phone camera.
public enum TerminalQR {
    public static func render(_ payload: PairingQRPayload, quietZone: Int = 2) -> String? {
        guard let data = try? payload.encodedJSON() else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(output, toBitmap: &pixels, rowBytes: width * 4,
                       bounds: extent, format: .RGBA8, colorSpace: nil)

        // Each QR module becomes one "██"/"  " cell; two rows per text line
        // keeps modules square in most terminal fonts.
        func isBlack(_ x: Int, _ y: Int) -> Bool? {
            guard x >= 0, x < width, y >= 0, y < height else { return nil }
            let offset = (y * width + x) * 4
            return pixels[offset] < 128
        }

        var lines: [String] = []
        let blank = String(repeating: " ", count: (width + quietZone * 2) * 2)
        for _ in 0..<quietZone { lines.append(blank) }
        // CIImage origin is bottom-left; QR scanners don't care which end we
        // print from only if the code is not mirrored — render top-down but
        // keep the row order stable by flipping explicitly.
        for y in stride(from: height - 1, through: 0, by: -1) {
            var line = String(repeating: " ", count: quietZone * 2)
            for x in 0..<width {
                line += isBlack(x, y) == true ? "██" : "  "
            }
            line += String(repeating: " ", count: quietZone * 2)
            lines.append(line)
        }
        for _ in 0..<quietZone { lines.append(blank) }
        return lines.joined(separator: "\n")
    }
}
