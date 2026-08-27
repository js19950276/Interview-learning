import CoreGraphics
import Foundation
import ImageIO

struct ImageBuffer {
    let width: Int
    let height: Int
    let bytes: [UInt8]
}

enum SnapshotError: Error, CustomStringConvertible {
    case unreadable(String)
    case dimensionMismatch(baseline: (Int, Int), current: (Int, Int))

    var description: String {
        switch self {
        case .unreadable(let path):
            "unable to read PNG: \(path)"
        case .dimensionMismatch(let baseline, let current):
            "dimension mismatch: baseline \(baseline.0)x\(baseline.1), current \(current.0)x\(current.1)"
        }
    }
}

func loadImage(at path: String) throws -> ImageBuffer {
    let url = URL(fileURLWithPath: path) as CFURL
    guard
        let source = CGImageSourceCreateWithURL(url, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw SnapshotError.unreadable(path)
    }

    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drewImage = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
        guard let baseAddress = rawBuffer.baseAddress,
              let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }

    guard drewImage else { throw SnapshotError.unreadable(path) }
    return ImageBuffer(width: width, height: height, bytes: bytes)
}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: SnapshotDiff.swift baseline.png current.png\n", stderr)
    exit(2)
}

do {
    let baseline = try loadImage(at: CommandLine.arguments[1])
    let current = try loadImage(at: CommandLine.arguments[2])
    guard baseline.width == current.width, baseline.height == current.height else {
        throw SnapshotError.dimensionMismatch(
            baseline: (baseline.width, baseline.height),
            current: (current.width, current.height)
        )
    }

    var differentPixels = 0
    let pixelCount = baseline.width * baseline.height
    for offset in stride(from: 0, to: baseline.bytes.count, by: 4) {
        let differs = (0..<4).contains { channel in
            abs(Int(baseline.bytes[offset + channel]) - Int(current.bytes[offset + channel])) > 12
        }
        if differs { differentPixels += 1 }
    }

    let ratio = Double(differentPixels) / Double(pixelCount)
    print(String(format: "different pixels: %.4f%% (%d/%d)", ratio * 100, differentPixels, pixelCount))
    exit(ratio > 0.005 ? 1 : 0)
} catch {
    fputs("snapshot comparison failed: \(error)\n", stderr)
    exit(1)
}
