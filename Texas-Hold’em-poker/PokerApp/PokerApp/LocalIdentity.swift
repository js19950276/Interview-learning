import Foundation

/// 本机稳定身份：断线重连的凭证（spec §6.2 hello.deviceID）。
enum LocalIdentity {
    private static let key = "poker.deviceID"

    static let deviceID: String = {
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty { return stored }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()
}
