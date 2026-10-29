import XCTest
@testable import PokerApp

/// 帧编解码：字节序/粘包/半包/坏帧（移植 Brass LocalNetworkTransportTests 的对应用例）。
final class TransportCodecTests: XCTestCase {
    func testFrameUsesFourByteBigEndianLengthPrefix() throws {
        let framed = try LengthPrefixedFrameCodec.frame(Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(Array(framed), [0, 0, 0, 3, 0xAA, 0xBB, 0xCC])
    }

    func testEmptyPayloadIsRejected() {
        XCTAssertThrowsError(try LengthPrefixedFrameCodec.frame(Data())) { error in
            XCTAssertEqual(error as? TransportError, .zeroLengthFrame)
        }
    }

    func testDecoderHandlesSplitAndCoalescedReadsInOrder() throws {
        var decoder = LengthPrefixedFrameCodec.Decoder()
        let first = try LengthPrefixedFrameCodec.frame(Data("one".utf8))
        let second = try LengthPrefixedFrameCodec.frame(Data("two".utf8))
        XCTAssertEqual(try decoder.append(first.prefix(2)), [])
        XCTAssertEqual(try decoder.append(first.dropFirst(2) + second),
                       [Data("one".utf8), Data("two".utf8)])
    }

    func testMalformedLengthPermanentlyShutsDecoder() throws {
        for length in [0, LengthPrefixedFrameCodec.maximumFrameSize + 1] {
            var decoder = LengthPrefixedFrameCodec.Decoder()
            let prefix = Data([
                UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
                UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
            ])
            let expected: TransportError = length == 0 ? .zeroLengthFrame : .frameTooLarge
            XCTAssertThrowsError(try decoder.append(prefix)) { error in
                XCTAssertEqual(error as? TransportError, expected)
            }
            XCTAssertThrowsError(try decoder.append(Data([0, 0, 0, 1, 7]))) { error in
                XCTAssertEqual(error as? TransportError, .decoderShutDown)
            }
        }
    }
}
