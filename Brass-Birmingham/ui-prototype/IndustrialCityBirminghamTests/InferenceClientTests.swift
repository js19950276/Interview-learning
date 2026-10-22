import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// P2 Task 4:推理帧协议编解码 + 客户端错误路径。
struct InferenceClientTests {
    @Test func requestFrameRoundTripsThroughPythonSideLayout() {
        let batch: [[Float]] = [
            (0..<GameCore.NeuralProtocol.featureDim).map { Float($0 % 97) * 0.25 },
            (0..<GameCore.NeuralProtocol.featureDim).map { Float(($0 * 7) % 53) * -0.5 },
        ]
        let data = GameCore.NeuralProtocol.encodeRequest(batch: batch)
        // 头:count(4) + dim(4);体:2×1549×2 字节。
        #expect(data.count == 8 + 2 * GameCore.NeuralProtocol.featureDim * 2)
        let count = data.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        #expect(count == 2)
        // f16 首值往返(容差:f16 精度)。
        let firstHalf = data.withUnsafeBytes { raw -> UInt16 in
            (raw.load(fromByteOffset: 8, as: UInt16.self)).littleEndian
        }
        let decoded = Float(Float16(bitPattern: firstHalf))
        #expect(abs(decoded - batch[0][0]) < 0.01)
    }

    @Test func responseFrameDecodesThreeHeads() throws {
        let count = 3
        var payload = Data()
        var countLE = UInt32(count).littleEndian
        payload.append(Data(bytes: &countLE, count: 4))
        var reference: [[Float]] = []
        for sample in 0..<count {
            var row: [Float] = []
            for a in 0..<GameCore.NeuralProtocol.policyAKinds {
                let v = Float(sample * 43 + a) * 0.1 - 1
                var f = v.bitPattern.littleEndian
                payload.append(Data(bytes: &f, count: 4))
                row.append(v)
            }
            for b in 0..<GameCore.NeuralProtocol.policyBCards {
                let v = Float(sample * 17 + b) * 0.05
                var f = v.bitPattern.littleEndian
                payload.append(Data(bytes: &f, count: 4))
                row.append(v)
            }
            for v0 in 0..<GameCore.NeuralProtocol.valuePlayers {
                let v = Float(v0) / 4 + Float(sample) * 0.01
                var f = v.bitPattern.littleEndian
                payload.append(Data(bytes: &f, count: 4))
                row.append(v)
            }
            reference.append(row)
        }
        let decoded = try GameCore.NeuralProtocol.decodeResponse(payload)
        #expect(decoded.logitsA.count == 3)
        #expect(decoded.logitsB[2][30] == reference[2][8 + 30])
        #expect(decoded.values[0][3] == reference[0][8 + 31 + 3])
        #expect(decoded.logitsA[1][0] == reference[1][0])
    }

    @Test func truncatedResponseThrows() {
        #expect(throws: GameCore.InferenceError.truncatedResponse) {
            _ = try GameCore.NeuralProtocol.decodeResponse(Data([0x01, 0x00, 0x00, 0x00]))
        }
    }

    @Test func connectionRefusedOnUnusedPort() {
        // 端口 9(discard 协议口,本机未开)——连接应失败而非挂死。
        let client = GameCore.InferenceClient(host: "127.0.0.1", port: 9)
        #expect(throws: GameCore.InferenceError.self) {
            _ = try client.evaluate(batch: [[Float](repeating: 0, count: GameCore.NeuralProtocol.featureDim)])
        }
    }
}
