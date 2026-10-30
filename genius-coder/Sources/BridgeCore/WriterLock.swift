import Foundation
import Darwin
import PhoneProtocol

/// Per-conversation single-writer exclusion (spec: 写入者锁).
///
/// Acquire order, exactly as the spec prescribes:
/// 1. In-process mutex per conversation id — held from send until turn end
///    (needs_approval does NOT release it).
/// 2. If a lock file is configured: exclusive `flock(LOCK_EX | LOCK_NB)` on an
///    FD we open ourselves. `EWOULDBLOCK` means a desktop writer holds it.
///    A 0-byte file by itself is not a lock — only the flock counts.
/// 3. Otherwise we take the flock and keep the FD open for the lease lifetime.
/// 4. For each existing watch path, `/usr/sbin/lsof -Fp` (2s timeout): any
///    foreign pid with the session file open means a desktop CLI is live.
/// 5. Only then is the lease granted.
/// Convenience top-level alias: the lease is always obtained from a
/// `WriterLock` but is commonly stored alongside conversation state.
public typealias WriterLease = WriterLock.WriterLease

public final class WriterLock: @unchecked Sendable {

    /// Advisory snapshot used by `conversation.open` state reporting.
    public struct Probe: Equatable {
        public var writer: SessionWriter
        public var detail: String?

        public init(writer: SessionWriter, detail: String?) {
            self.writer = writer
            self.detail = detail
        }
    }

    public enum AcquireResult {
        case acquired(WriterLease)
        /// `byDesktop` distinguishes a desktop CLI writer (true) from the
        /// bridge's own in-process turn (false). `detail` maps to the state
        /// machine's detail field / `writer_locked` error code.
        case locked(byDesktop: Bool, detail: String?)
    }

    /// A held writer lock for one conversation. Released explicitly via
    /// `release()` or implicitly on deinit; the same conversation cannot be
    /// re-acquired in-process while the lease is alive.
    public final class WriterLease: @unchecked Sendable {
        public let conversationId: String
        fileprivate weak var owner: WriterLock?
        fileprivate var lockFD: Int32?
        private let guardLock = NSLock()
        private var released = false

        fileprivate init(owner: WriterLock, conversationId: String, lockFD: Int32?) {
            self.owner = owner
            self.conversationId = conversationId
            self.lockFD = lockFD
        }

        /// Idempotent. Drops the flock (if held) and the in-process mutex.
        public func release() {
            guardLock.lock()
            defer { guardLock.unlock() }
            guard !released else { return }
            released = true
            let fd = lockFD
            lockFD = nil
            owner?.unregister(conversationId: conversationId, lease: self)
            if let fd {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }

        deinit {
            release()
        }
    }

    /// Weak box so the holder table never keeps a lease alive (a strong table
    /// could trigger deinit — and thus queue.sync — on the lock's own queue).
    private struct WeakLease {
        weak var value: WriterLease?
    }

    private let queue = DispatchQueue(label: "genius-coder.writerlock")
    private var holders: [String: WeakLease] = [:]
    /// Conversations mid-acquire (flock/lsof checks running).
    private var reservations: Set<String> = []

    public init() {}

    // MARK: - Acquire

    public func acquire(
        conversationId: String,
        lockFile: String?,
        watchPaths: [String],
        agentProcessNames: [String]
    ) -> AcquireResult {
        // 1) In-process mutex, held from send until turn end.
        let reserved = queue.sync { () -> Bool in
            if holders[conversationId]?.value != nil || reservations.contains(conversationId) {
                return false
            }
            reservations.insert(conversationId)
            return true
        }
        guard reserved else {
            return .locked(byDesktop: false, detail: "turn_in_progress")
        }

        // 2/3) flock the lock file ourselves, keeping the FD for the lease.
        var heldFD: Int32?
        if let lockFile {
            switch Self.tryTakeFlock(path: lockFile) {
            case .taken(let fd):
                heldFD = fd
            case .heldElsewhere:
                queue.sync { _ = reservations.remove(conversationId) }
                return .locked(byDesktop: true, detail: "writer_locked")
            case .unavailable:
                // Cannot enforce the file lock (permissions/missing dir);
                // the lsof check below still guards. Fail open with a log.
                BridgeLog.net.error("writer lock file unavailable: \(lockFile, privacy: .public)")
            }
        }

        // 4) lsof: any foreign pid holding a watch path open = desktop writer.
        if let holderDetail = foreignHolderDetail(watchPaths: watchPaths, agentProcessNames: agentProcessNames) {
            if let fd = heldFD {
                flock(fd, LOCK_UN)
                close(fd)
            }
            queue.sync { _ = reservations.remove(conversationId) }
            return .locked(byDesktop: true, detail: holderDetail)
        }

        // 5) Granted.
        let lease = WriterLease(owner: self, conversationId: conversationId, lockFD: heldFD)
        queue.sync {
            holders[conversationId] = WeakLease(value: lease)
            reservations.remove(conversationId)
        }
        return .acquired(lease)
    }

    /// Same checks without taking the in-process mutex — used by
    /// `conversation.open` to report `SessionState.writer`.
    public func probe(
        conversationId: String,
        lockFile: String?,
        watchPaths: [String],
        agentProcessNames: [String]
    ) -> Probe {
        let inProcess = queue.sync { () -> Bool in
            holders[conversationId]?.value != nil || reservations.contains(conversationId)
        }
        if inProcess {
            return Probe(writer: .bridge, detail: "turn_in_progress")
        }
        if let lockFile {
            switch Self.tryTakeFlock(path: lockFile) {
            case .heldElsewhere:
                return Probe(writer: .desktop, detail: "writer_locked")
            case .taken(let fd):
                flock(fd, LOCK_UN)
                close(fd)
            case .unavailable:
                BridgeLog.net.error("writer lock file unavailable: \(lockFile, privacy: .public)")
            }
        }
        if let holderDetail = foreignHolderDetail(watchPaths: watchPaths, agentProcessNames: agentProcessNames) {
            return Probe(writer: .desktop, detail: holderDetail)
        }
        return Probe(writer: .none, detail: nil)
    }

    // MARK: - Internals

    fileprivate func unregister(conversationId: String, lease: WriterLease) {
        queue.sync {
            if holders[conversationId]?.value === lease {
                holders[conversationId] = nil
            }
            reservations.remove(conversationId)
        }
    }

    private enum FlockOutcome {
        case taken(Int32)
        case heldElsewhere
        case unavailable
    }

    private static func tryTakeFlock(path: String) -> FlockOutcome {
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return .unavailable }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return .taken(fd)
        }
        let savedErrno = errno
        close(fd)
        if savedErrno == EWOULDBLOCK {
            return .heldElsewhere
        }
        return .unavailable
    }

    /// First foreign holder of any existing watch path, as a state detail
    /// string, or nil when every watch path is free. Any pid other than ours
    /// counts (spec: 写入者锁); when agent process names are known the detail
    /// names the CLI instead of the bare pid.
    private func foreignHolderDetail(watchPaths: [String], agentProcessNames: [String]) -> String? {
        let fileManager = FileManager.default
        for path in watchPaths where fileManager.fileExists(atPath: path) {
            for pid in Self.lsofPids(path: path) where pid != getpid() {
                if agentProcessNames.isEmpty {
                    return "session_open:\(pid)"
                }
                if let name = Self.processName(pid: pid) {
                    let base = (name as NSString).lastPathComponent
                    if agentProcessNames.contains(name) || agentProcessNames.contains(base) {
                        return "cli_running:\(base)"
                    }
                }
                return "session_open:\(pid)"
            }
        }
        return nil
    }

    /// `/usr/sbin/lsof -Fp <path>` with a 2s budget. Lines starting with 'p'
    /// carry pids. Timeout or spawn failure yields no pids.
    private static func lsofPids(path: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-Fp", path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            return []
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line -> pid_t? in
            guard line.first == "p" else { return nil }
            return pid_t(String(line.dropFirst()))
        }
    }

    /// Best-effort `/bin/ps -o comm= -p <pid>` (1s budget).
    private static func processName(pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "comm=", "-p", String(pid)]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 1) != .timedOut else {
            process.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
