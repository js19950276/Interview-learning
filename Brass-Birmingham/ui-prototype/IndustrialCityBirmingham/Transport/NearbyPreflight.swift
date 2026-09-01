import Foundation
import CryptoKit
import Network

nonisolated enum NearbyPreflightIssue: String, Equatable, Error, Sendable {
    case permissionDenied
    case wirelessOff
    case noRooms
    case connectionFailed
    case sessionEnded
    case gameDataUnavailable
    case persistenceUnavailable

    var title: String {
        switch self {
        case .permissionDenied: "未获本地网络权限"
        case .wirelessOff: "Wi-Fi 当前不可用"
        case .noRooms: "附近没有开放房间"
        case .connectionFailed: "无法连接房间"
        case .sessionEnded: "房间连接已结束"
        case .gameDataUnavailable: "游戏数据不可用"
        case .persistenceUnavailable: "无法安全保存座位"
        }
    }

    var recoveryMessage: String {
        switch self {
        case .permissionDenied:
            "请前往系统设置，允许工业城市使用本地网络，然后返回重试。"
        case .wirelessOff:
            "飞行模式可以保持开启；如果系统关闭了 Wi-Fi，请在控制中心重新打开 Wi-Fi 后重试。"
        case .noRooms:
            "让一台设备先创建房间，并确认 Wi-Fi 已打开，然后重试搜索。"
        case .connectionFailed:
            "请靠近房主、保持房主页面打开，然后重试加入。"
        case .sessionEnded:
            "请返回附近房间列表，重新创建或加入房间。"
        case .gameDataUnavailable:
            "当前规则数据未通过校验，暂时无法创建、加入或恢复正式对局。"
        case .persistenceUnavailable:
            "房主暂时无法安全保存你的座位，请让房主保持房间页面打开，然后重试加入。"
        }
    }
}

nonisolated struct NearbySessionIdentity: Equatable, Sendable {
    private static let processFallbackDeviceID = UUID()
    let playerID: GameCore.PlayerID
    let shortID: String
    private let credentialSeed: String

    init(deviceID: UUID) {
        let canonical = deviceID.uuidString.lowercased()
        shortID = String(canonical.prefix(8))
        playerID = .init(rawValue: "guest-\(shortID)")
        credentialSeed = canonical
    }

    func reconnectToken(for roomID: GameCore.RoomID) -> GameCore.ReconnectToken {
        let material = Data(
            "industrial-city-nearby-v2\u{001F}\(credentialSeed)\u{001F}\(roomID.rawValue)".utf8
        )
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return .init(rawValue: "nearby-v2-\(digest)")
    }

    static func make(deviceID: UUID?) -> NearbySessionIdentity {
        NearbySessionIdentity(deviceID: deviceID ?? processFallbackDeviceID)
    }
}

nonisolated enum NearbyPreflight {
    static func issue(for error: any Error) -> NearbyPreflightIssue {
        if let issue = error as? NearbyPreflightIssue { return issue }
        if error is GameCore.GameDataLoadError { return .gameDataUnavailable }
        if error as? SessionCoordinator.Error == .dataUnavailable { return .gameDataUnavailable }
        if error as? SessionCoordinator.Error == .persistenceUnavailable { return .persistenceUnavailable }
        if let networkError = error as? NWError { return issue(for: networkError) }
        if let transportError = error as? TransportError {
            return transportError == .notConnected ? .noRooms : .connectionFailed
        }
        return .connectionFailed
    }

    static func issue(for error: NWError) -> NearbyPreflightIssue {
        switch error {
        case let .posix(code):
            switch code {
            case .EPERM, .EACCES: .permissionDenied
            case .ENETDOWN, .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH: .wirelessOff
            default: .connectionFailed
            }
        case let .dns(code) where code == -65570: .permissionDenied
        default: .connectionFailed
        }
    }
}
