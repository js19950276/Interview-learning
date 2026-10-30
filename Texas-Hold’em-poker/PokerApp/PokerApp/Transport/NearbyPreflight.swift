import Foundation
import Network

nonisolated enum NearbyIssue: String, Equatable, Error, Sendable {
    case permissionDenied
    case wirelessOff
    case connectionFailed

    var title: String {
        switch self {
        case .permissionDenied: "未获本地网络权限"
        case .wirelessOff: "Wi-Fi 当前不可用"
        case .connectionFailed: "无法连接房间"
        }
    }

    var recoveryMessage: String {
        switch self {
        case .permissionDenied:
            "请前往系统设置，允许德州扑克使用本地网络，然后返回重试。"
        case .wirelessOff:
            "如果系统关闭了 Wi-Fi，请在控制中心重新打开后重试；同一路由器或面对面点对点 Wi-Fi 均可。"
        case .connectionFailed:
            "请靠近房主、保持房主页面打开，然后重试。"
        }
    }
}

nonisolated enum NearbyPreflight {
    static func issue(for error: any Error) -> NearbyIssue {
        if let issue = error as? NearbyIssue { return issue }
        if let networkError = error as? NWError { return issue(for: networkError) }
        if error is TransportError { return .connectionFailed }
        return .connectionFailed
    }

    static func issue(for error: NWError) -> NearbyIssue {
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
