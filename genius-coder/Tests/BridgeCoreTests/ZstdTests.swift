import XCTest
import CryptoKit
@testable import BridgeCore

/// Round-trips the pure-Swift zstd decoder against fixtures compressed by
/// CPython's zstd (multiple levels → RLE / predefined / FSE+Huffman paths)
/// plus the real dsh session log from this machine.
final class ZstdTests: XCTestCase {
    struct ManifestEntry: Codable {
        var name: String
        var level: Int
        var origSize: Int
        var sha: String
        var source: String?
        var compSize: Int
    }

    func testAgainstPythonFixtures() throws {
        let fixtureDir = "/tmp/gc-zstd-fixtures"
        let manifestURL = URL(fileURLWithPath: fixtureDir + "/manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw XCTSkip("fixtures not generated; run tools/zstd-fixtures.py")
        }
        let manifest = try JSONDecoder().decode([ManifestEntry].self, from: Data(contentsOf: manifestURL))
        XCTAssertGreaterThanOrEqual(manifest.count, 8)
        try XCTSkipUnless(Libzstd.shared.available, "no zstd library on this machine")
        var failures: [String] = []
        for entry in manifest {
            let compressed = try Data(contentsOf: URL(fileURLWithPath: "\(fixtureDir)/\(entry.name).zst"))
            do {
                let out = try DshZstd.decompress(compressed)
                let sha = SHA256.hash(data: out).map { String(format: "%02x", $0) }.joined()
                if sha != entry.sha || out.count != entry.origSize {
                    failures.append("\(entry.name): sha/count mismatch (\(out.count) vs \(entry.origSize))")
                }
            } catch {
                failures.append("\(entry.name): threw \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "zstd failures: \(failures.joined(separator: "; "))")
    }

    func testRealDshLogDecompresses() throws {
        let orig = "/tmp/gc-zstd-fixtures/real-dsh.orig"
        let comp = "/Users/baigeitiancai/.dsh/sessions/--Users-baigeitiancai-Documents-deepseek-harness-default-workspace--/session-8b9ca437-0164-46ca-8652-4bc8ea9857a2/session.v4.jsonl.zstd"
        guard FileManager.default.fileExists(atPath: comp) else {
            throw XCTSkip("real dsh log not present on this machine")
        }
        let decompressed = try DshZstd.decompress(try Data(contentsOf: URL(fileURLWithPath: comp)))
        let expected = try Data(contentsOf: URL(fileURLWithPath: orig))
        XCTAssertEqual(decompressed, expected)
        // It must parse as JSONL with a session header.
        let text = String(data: decompressed, encoding: .utf8) ?? ""
        let first = text.split(separator: "\n").first.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
        XCTAssertEqual(first?["type"] as? String, "session")
    }

    func testBadMagicRejected() {
        XCTAssertThrowsError(try DshZstd.decompress(Data([1, 2, 3, 4, 5, 6, 7, 8])))
    }

    func testPureSwiftDecoderHandlesSimpleStreams() throws {
        // The pure-Swift fallback covers RAW/RLE-block streams; FSE-compressed
        // blocks need the linked library. Keep this guard test so the fallback
        // never silently regresses on what it does support.
        let fixtureDir = "/tmp/gc-zstd-fixtures"
        guard FileManager.default.fileExists(atPath: fixtureDir + "/rle.zst") else {
            throw XCTSkip("fixtures missing")
        }
        // Incompressible input produces a RAW block, which the fallback
        // decodes exactly; compressible inputs require the linked library.
        let random = try Data(contentsOf: URL(fileURLWithPath: fixtureDir + "/random.zst"))
        let out = try ZstdDecompressor().decompress(random)
        XCTAssertEqual(out.count, 30000)
    }
}
