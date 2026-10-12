import Foundation

/// 轻量明文诊断日志:每次意图提交与权威事件落地各记一行,
/// 写入 App 沙盒 Documents/session-diagnostics.log(不加密),
/// 便于事后从设备拉取排查对局问题(如撤回后建造扣费异常)。
nonisolated final class SessionDiagnosticsWriter: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var fileHandle: FileHandle?

    private var fileURL: URL? {
        FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first?.appending(path: "session-diagnostics.log")
    }

    func write(_ line: String) {
        guard let url = fileURL else { return }
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        let data = Data(stamped.utf8)
        lock.lock()
        defer { lock.unlock() }
        do {
            if let handle = fileHandle {
                try handle.write(contentsOf: data)
                return
            }
            if FileManager.default.fileExists(atPath: url.path) == false {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            fileHandle = handle
            try handle.write(contentsOf: data)
        } catch {
            fileHandle = nil
        }
    }
}

nonisolated enum SessionDiagnostics {
    private static let writer = SessionDiagnosticsWriter()

    static func log(_ line: String) {
        writer.write(line)
    }

    static func describe(_ payload: GameCore.PlayerIntent.Payload) -> String {
        switch payload {
        case .pass(let intent): return "pass(\(intent.cardID))"
        case .build(let intent): return "build(\(intent.industryDefinitionID) @ \(intent.locationID))"
        case .network(let intent): return "network(\(intent.routeIDs.joined(separator: "+")))"
        case .develop(let intent): return "develop(\(intent.tileIDs.joined(separator: "+")))"
        case .sell(let intent): return "sell(\(intent.sales.count))"
        case .loan(let intent): return "loan(\(intent.cardID))"
        case .scout(let intent): return "scout(\(intent.cardIDs.count))"
        case .forcedSale(let intent): return "forcedSale(\(intent.placementIDs.count))"
        case .confirmEraIntermission: return "confirmEra"
        case .confirmTurnEnd: return "confirmTurnEnd"
        case .retractTurnActions: return "retractTurn"
        }
    }

    static func describe(_ payload: GameCore.AuthoritativeGameEvent.Payload) -> String {
        switch payload {
        case .passed(let cardID): return "passed(\(cardID))"
        case .built(let intent, _, _): return "built(\(intent.industryDefinitionID) @ \(intent.locationID))"
        case .networkBuilt(let intent, _, _): return "networkBuilt(\(intent.routeIDs.joined(separator: "+")))"
        case .developed(let intent, _, _): return "developed(\(intent.tileIDs.joined(separator: "+")))"
        case .sold(let intent, _, _): return "sold(\(intent.sales.count))"
        case .loanTaken(let intent, let previous, let current): return "loanTaken(\(intent.cardID) \(previous)→\(current))"
        case .scouted: return "scouted"
        case .forcedSaleResolved(let intent): return "forcedSaleResolved(\(intent.placementIDs.count))"
        case .eraIntermissionConfirmed(let playerID): return "eraConfirmed(\(playerID.rawValue))"
        case .turnEndConfirmed(let playerID): return "turnEndConfirmed(\(playerID.rawValue))"
        case .turnActionsRetracted(let playerID, let from, let count):
            return "turnRetracted(\(playerID.rawValue) from=v\(from.rawValue) count=\(count))"
        }
    }
}
