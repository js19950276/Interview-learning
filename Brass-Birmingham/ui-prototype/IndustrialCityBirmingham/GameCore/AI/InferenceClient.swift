import Darwin
import Foundation

extension GameCore {
    /// P2 帧协议常量(三端共享,与 tools/training/bb.py 逐一对应;改动须双端同步)。
    nonisolated enum NeuralProtocol {
        static let featuresVersion = 1
        static let featureDim = 1549
        static let policyAKinds = 8
        static let policyBCards = 31
        static let valuePlayers = 4
        /// 请求帧:u32 count + u32 dim + count×dim×f16(LE)。
        /// 响应帧:u32 count + count×(f32[8] + f32[31] + f32[4]),共 43 个 f32/样本。
        static let responseFloatsPerSample = policyAKinds + policyBCards + valuePlayers

        static func encodeRequest(batch: [[Float]]) -> Data {
            var count = UInt32(batch.count).littleEndian
            var dim = UInt32(batch.count > 0 ? batch[0].count : 0).littleEndian
            var data = Data(bytes: &count, count: 4)
            data.append(Data(bytes: &dim, count: 4))
            for features in batch {
                precondition(features.count == Int(dim), "批内维度不一致")
                for value in features {
                    // Float16.bitPattern 是 Int16;字节序才重要,符号位按原样写出。
                    var half = Float16(value).bitPattern.littleEndian
                    data.append(Data(bytes: &half, count: 2))
                }
            }
            return data
        }

        struct InferenceBatch: Equatable, Sendable {
            var logitsA: [[Float]]   // [count][8]
            var logitsB: [[Float]]   // [count][31]
            var values: [[Float]]    // [count][4]
        }

        static func decodeResponse(_ data: Data) throws -> InferenceBatch {
            guard data.count >= 4 else { throw InferenceError.truncatedResponse }
            let count = data.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let expected = 4 + Int(count) * responseFloatsPerSample * 4
            guard data.count == expected else { throw InferenceError.truncatedResponse }
            var floats = [Float](repeating: 0, count: Int(count) * responseFloatsPerSample)
            _ = floats.withUnsafeMutableBytes { buffer in
                data.withUnsafeBytes { raw in
                    memcpy(buffer.baseAddress, raw.baseAddress! + 4, buffer.count)
                }
            }
            var batch = InferenceBatch(logitsA: [], logitsB: [], values: [])
            batch.logitsA.reserveCapacity(Int(count))
            batch.logitsB.reserveCapacity(Int(count))
            batch.values.reserveCapacity(Int(count))
            var cursor = 0
            for _ in 0..<count {
                batch.logitsA.append(Array(floats[cursor..<(cursor + policyAKinds)]))
                cursor += policyAKinds
                batch.logitsB.append(Array(floats[cursor..<(cursor + policyBCards)]))
                cursor += policyBCards
                batch.values.append(Array(floats[cursor..<(cursor + valuePlayers)]))
                cursor += valuePlayers
            }
            return batch
        }
    }

    nonisolated enum InferenceError: Error, Equatable, Sendable {
        case connectionFailed
        case truncatedResponse
        case sendFailed
        case receiveFailed
    }

    /// 阻塞式 TCP 推理客户端(macOS 自博弈 CLI 用;P3 换 CoreML)。
    /// 非并发域共享——每游戏进程各持一个。
    nonisolated final class InferenceClient: @unchecked Sendable {
        private let host: String
        private let port: UInt16
        private var fileDescriptor: Int32 = -1

        init(host: String = "127.0.0.1", port: UInt16) {
            self.host = host
            self.port = port
        }

        deinit { disconnect() }

        func disconnect() {
            if fileDescriptor >= 0 {
                close(fileDescriptor)
                fileDescriptor = -1
            }
        }

        private func ensureConnected() throws {
            guard fileDescriptor < 0 else { return }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw InferenceError.connectionFailed }
            // 对端关闭时 send 触发 SIGPIPE 会直接杀进程(exit 141)而非走设计好的
            // 错误路径;Darwin 无 MSG_NOSIGNAL,必须套接字级关掉(终审 I5)。
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            // 收发超时(计划 Task 4:10s)——服务挂起时自博弈不得永久卡死。
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            inet_pton(AF_INET, host, &address.sin_addr)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                close(fd)
                throw InferenceError.connectionFailed
            }
            fileDescriptor = fd
        }

        private func sendAll(_ data: Data) throws {
            var sent = 0
            try data.withUnsafeBytes { raw in
                while sent < data.count {
                    let written = send(fileDescriptor, raw.baseAddress! + sent, data.count - sent, 0)
                    guard written > 0 else { throw InferenceError.sendFailed }
                    sent += written
                }
            }
        }

        private func receiveExactly(_ byteCount: Int) throws -> Data {
            var buffer = Data(count: byteCount)
            var received = 0
            try buffer.withUnsafeMutableBytes { raw in
                while received < byteCount {
                    let chunk = recv(fileDescriptor, raw.baseAddress! + received, byteCount - received, 0)
                    guard chunk > 0 else { throw InferenceError.receiveFailed }
                    received += chunk
                }
            }
            return buffer
        }

        /// 单样本便捷入口(MCTS 叶评估/先验用)。
        func evaluateSingle(_ features: [Float]) throws -> NeuralProtocol.InferenceBatch {
            try evaluate(batch: [features])
        }

        func evaluate(batch: [[Float]]) throws -> NeuralProtocol.InferenceBatch {
            try ensureConnected()
            try sendAll(NeuralProtocol.encodeRequest(batch: batch))
            let header = try receiveExactly(4)
            let count = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let body = try receiveExactly(Int(count) * NeuralProtocol.responseFloatsPerSample * 4)
            return try NeuralProtocol.decodeResponse(header + body)
        }
    }
}
