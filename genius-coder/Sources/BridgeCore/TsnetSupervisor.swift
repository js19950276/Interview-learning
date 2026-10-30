import Foundation
import PhoneProtocol

/// Layer ②: embedded userspace Tailscale. The bridge supervises the
/// `gc-tsnet-helper` binary (static Go build with tsnet, no TUN, no
/// NetworkExtension, no official Tailscale apps on either side — a
/// deliberate deviation from the spec's "personal Tailscale apps" model,
/// adopted so the Mac runs one command and the phone installs one app).
///
/// Stdout line protocol from the helper:
///   STATE <starting|running>     LOGINURL <url>     READY <ip> <port>     ERROR <msg>
public final class TsnetSupervisor: @unchecked Sendable {
    public struct Status {
        public var tailscaleIP: String?
        public var port: UInt16?
        public var loginURL: String?
        public var lastError: String?
        public var running: Bool

        public var hostEntry: PairingQRPayload.Host? {
            guard let ip = tailscaleIP, let port else { return nil }
            _ = port
            return PairingQRPayload.Host(address: ip, kind: "tailscale")
        }
    }

    private let queue = DispatchQueue(label: "genius-coder.tsnet")
    private var process: LineProcess?
    private var current = Status(tailscaleIP: nil, port: nil, loginURL: nil, lastError: nil, running: false)
    private var authKey: String?
    private var loginServer: String?
    private var hostname: String
    private var bridgePort: UInt16

    /// Resolved when the helper reports READY (or fails).
    private var readyContinuations: [CheckedContinuation<Status, Never>] = []

    public static func defaultHelperPath() -> String? {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["GENIUS_CODER_TSNET_HELPER"] {
            candidates.append(override)
        }
        if let exe = CommandLine.arguments.first {
            let dir = (exe as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                candidates.append(dir + "/gc-tsnet-helper")
                candidates.append(dir + "/bin/gc-tsnet-helper")
            }
        }
        candidates.append("/usr/local/bin/gc-tsnet-helper")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("genius-coder/bin/gc-tsnet-helper").path
        candidates.append(support)
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    public init(hostname: String = "genius-coder-bridge", bridgePort: UInt16) {
        self.hostname = hostname
        self.bridgePort = bridgePort
        self.authKey = ProcessInfo.processInfo.environment["TS_AUTHKEY"]
        self.loginServer = ProcessInfo.processInfo.environment["TS_LOGIN_SERVER"]
    }

    public func status() -> Status {
        queue.sync { current }
    }

    public var isConfigured: Bool {
        Self.defaultHelperPath() != nil
    }

    /// Spawn the helper and wait (up to `timeout`) for READY. Returns the
    /// final status even on timeout — the phone only uses the tailscale
    /// host when present.
    @discardableResult
    public func start(timeout: TimeInterval = 90) async -> Status {
        if let existing = queue.sync(execute: { process }), existing.isRunning {
            return await whenReady(timeout: timeout)
        }
        guard let path = Self.defaultHelperPath() else {
            queue.sync {
                current.lastError = "gc-tsnet-helper not found (set GENIUS_CODER_TSNET_HELPER)"
            }
            return status()
        }
        let proc = LineProcess(label: "gc-tsnet")
        proc.onLine = { [weak self] line in
            self?.ingest(line: line)
        }
        proc.onStderr = { text in
            BridgeLog.net.debug("tsnet stderr: \(text, privacy: .public)")
        }
        var arguments = ["--hostname", hostname, "--bridge", "127.0.0.1:\(bridgePort)", "--port", String(bridgePort)]
        if let key = authKey { arguments += ["--authkey", key] }
        if let server = loginServer { arguments += ["--login-server", server] }
        do {
            _ = try proc.run(executable: path, arguments: arguments)
        } catch {
            queue.sync { current.lastError = "spawn failed: \(error.localizedDescription)" }
            return status()
        }
        queue.sync {
            process = proc
            current = Status(tailscaleIP: nil, port: nil, loginURL: nil, lastError: nil, running: true)
        }
        return await whenReady(timeout: timeout)
    }

    public func stop() {
        queue.sync {
            process?.terminate()
            process = nil
            current.running = false
            current.tailscaleIP = nil
        }
        flushReady()
    }

    private func whenReady(timeout: TimeInterval) async -> Status {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = status()
            if snapshot.tailscaleIP != nil || snapshot.lastError != nil {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return status()
    }

    private func ingest(line: String) {
        if line.hasPrefix("READY ") {
            let parts = line.dropFirst("READY ".count).split(separator: " ").map(String.init)
            guard parts.count >= 2, let port = UInt16(parts[1]) else { return }
            queue.sync {
                current.tailscaleIP = parts[0]
                current.port = port
                current.running = true
            }
            BridgeLog.net.info("tsnet ready on \(parts[0], privacy: .public):\(port)")
            flushReady()
        } else if line.hasPrefix("LOGINURL ") {
            let url = String(line.dropFirst("LOGINURL ".count))
            queue.sync { current.loginURL = url }
            BridgeLog.net.info("tsnet needs interactive login")
        } else if line.hasPrefix("ERROR ") {
            let message = String(line.dropFirst("ERROR ".count))
            queue.sync {
                current.lastError = message
                current.running = false
            }
            BridgeLog.net.error("tsnet: \(message, privacy: .public)")
            flushReady()
        }
    }

    private func flushReady() {
        let waiters: [CheckedContinuation<Status, Never>] = queue.sync {
            let copy = readyContinuations
            readyContinuations.removeAll()
            return copy
        }
        let snapshot = status()
        for waiter in waiters {
            waiter.resume(returning: snapshot)
        }
    }
}
