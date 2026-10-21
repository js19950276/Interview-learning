import Foundation

// 与 Session/SnapshotStore.swift 的 JSONEncoder.canonical 逐字段一致(P2 自博弈 CLI 落地时应随包结构解决,此处为剖析 CLI 临时 shim)。
extension JSONEncoder {
    nonisolated static var canonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
