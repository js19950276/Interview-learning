import Foundation

nonisolated enum LengthPrefixedFrameCodec {
    static let maximumFrameSize = 1_048_576

    static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw TransportError.zeroLengthFrame }
        guard payload.count <= maximumFrameSize else { throw TransportError.frameTooLarge }
        var length = UInt32(payload.count).bigEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(payload)
        return framed
    }

    struct Decoder: Sendable {
        private var buffer = Data()
        private var isShutDown = false

        mutating func append<S: DataProtocol>(_ bytes: S) throws -> [Data] {
            guard !isShutDown else { throw TransportError.decoderShutDown }
            buffer.append(contentsOf: bytes)
            var frames: [Data] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0 else { return try shutDown(with: .zeroLengthFrame) }
                guard length <= LengthPrefixedFrameCodec.maximumFrameSize else { return try shutDown(with: .frameTooLarge) }
                guard buffer.count >= length + 4 else { break }
                let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
                let payloadEnd = buffer.index(payloadStart, offsetBy: length)
                frames.append(Data(buffer[payloadStart..<payloadEnd]))
                buffer = Data(buffer[payloadEnd...])
            }
            return frames
        }

        private mutating func shutDown(with error: TransportError) throws -> [Data] {
            isShutDown = true
            buffer.removeAll()
            throw error
        }
    }
}
