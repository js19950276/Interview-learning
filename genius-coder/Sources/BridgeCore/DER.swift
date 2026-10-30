import Foundation

/// Minimal DER encoder used to build the bridge's self-signed X.509
/// certificate. Only the subset needed for an ECDSA P-256 leaf is here.
enum DER {
    static func length(_ len: Int) -> [UInt8] {
        if len < 0x80 {
            return [UInt8(len)]
        }
        var bytes: [UInt8] = []
        var v = len
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [tag] + length(payload.count) + payload
    }

    static func sequence(_ children: [[UInt8]]) -> [UInt8] {
        tlv(0x30, children.flatMap { $0 })
    }

    static func set(_ children: [[UInt8]]) -> [UInt8] {
        tlv(0x31, children.flatMap { $0 })
    }

    static func integer(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        if v == 0 { bytes = [0] }
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    static func oid(_ arcs: [Int]) -> [UInt8] {
        var body: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            if arc < 0x80 {
                body.append(UInt8(arc))
            } else {
                var chunk: [UInt8] = []
                var v = arc
                while v > 0 {
                    chunk.insert(UInt8(v & 0x7F), at: 0)
                    v >>= 7
                }
                for (i, _) in chunk.enumerated() where i < chunk.count - 1 {
                    chunk[i] |= 0x80
                }
                body.append(contentsOf: chunk)
            }
        }
        return tlv(0x06, body)
    }

    static func utf8String(_ s: String) -> [UInt8] {
        tlv(0x0C, Array(s.utf8))
    }

    static func bitString(_ bytes: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] {
        tlv(0x03, [unusedBits] + bytes)
    }

    static func octetString(_ bytes: [UInt8]) -> [UInt8] {
        tlv(0x04, bytes)
    }

    static func utcTime(_ date: Date) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let yy = (c.year ?? 2000) % 100
        let s = String(format: "%02d%02d%02d%02d%02d%02dZ", yy, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return tlv(0x17, Array(s.utf8))
    }

    /// Context-tagged explicit wrapper, e.g. `[0] EXPLICIT`.
    static func explicit(_ index: UInt8, _ child: [UInt8]) -> [UInt8] {
        tlv(0xA0 | index, child)
    }

    // Well-known OIDs
    static let ecdsaWithSHA256 = oid([1, 2, 840, 10045, 4, 3, 2])
    static let ecPublicKey = oid([1, 2, 840, 10045, 2, 1])
    static let prime256v1 = oid([1, 2, 840, 10045, 3, 1, 7])
    static let commonName = oid([2, 5, 4, 3])
    static let basicConstraints = oid([2, 5, 29, 19])
    static let subjectAltName = oid([2, 5, 29, 17])
}
