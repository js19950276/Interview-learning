import Foundation
import GeniusTsnet

/// Thin façade over the gomobile framework's C API (Layer ②: in-app
/// userspace Tailscale; no official app, no NetworkExtension).
enum PhoneTsnet {
    static func status() -> String {
        GctsnetStatus()
    }

    static func start(authKey: String, hostname: String, stateDir: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: GctsnetStart(authKey, hostname, stateDir, 90))
            }
        }
    }

    static func startProxy(destination: String) -> UInt16? {
        let result = GctsnetStartProxy(destination)
        guard result.hasPrefix("port:") else { return nil }
        return UInt16(result.dropFirst("port:".count))
    }

    static func stop() {
        GctsnetStop()
    }
}
