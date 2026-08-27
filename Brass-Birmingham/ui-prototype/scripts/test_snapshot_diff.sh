#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
diff_script="$repo_root/scripts/SnapshotDiff.swift"

test -f "$diff_script"

fixture_dir="$(mktemp -d /tmp/industrial-city-snapshot-diff-test.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT

xcrun swift - "$fixture_dir" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func writeImage(path: String, width: Int, height: Int, changedPixels: Int, delta: UInt8) throws {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for pixel in 0..<(width * height) {
        bytes[pixel * 4] = 40
        bytes[pixel * 4 + 1] = 40
        bytes[pixel * 4 + 2] = 40
        bytes[pixel * 4 + 3] = 255
    }
    for pixel in 0..<min(changedPixels, width * height) {
        bytes[pixel * 4] = 40 + delta
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let directory = CommandLine.arguments[1]
try writeImage(path: "\(directory)/baseline.png", width: 20, height: 20, changedPixels: 0, delta: 0)
try writeImage(path: "\(directory)/same.png", width: 20, height: 20, changedPixels: 0, delta: 0)
try writeImage(path: "\(directory)/delta-12.png", width: 20, height: 20, changedPixels: 400, delta: 12)
try writeImage(path: "\(directory)/ratio-0.5.png", width: 20, height: 20, changedPixels: 2, delta: 13)
try writeImage(path: "\(directory)/ratio-0.75.png", width: 20, height: 20, changedPixels: 3, delta: 13)
try writeImage(path: "\(directory)/different-size.png", width: 21, height: 20, changedPixels: 0, delta: 0)
SWIFT

compare() {
  xcrun swift "$diff_script" "$fixture_dir/baseline.png" "$1"
}

compare "$fixture_dir/same.png"
compare "$fixture_dir/delta-12.png"
compare "$fixture_dir/ratio-0.5.png"

if compare "$fixture_dir/ratio-0.75.png"; then
  echo "expected ratio above 0.5% to fail" >&2
  exit 1
fi

dimension_error="$fixture_dir/dimension-error.txt"
if compare "$fixture_dir/different-size.png" 2>"$dimension_error"; then
  echo "expected dimension mismatch to fail" >&2
  exit 1
fi
grep -q "dimension mismatch" "$dimension_error"

usage_error="$fixture_dir/usage-error.txt"
set +e
xcrun swift "$diff_script" >"$usage_error" 2>&1
usage_status=$?
set -e
test "$usage_status" -eq 2
grep -q "usage:" "$usage_error"

echo "SnapshotDiff fixture self-test passed"
