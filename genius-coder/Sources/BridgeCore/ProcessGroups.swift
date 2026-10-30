import Foundation
import Darwin

/// Child process-group supervision (spec: Mac 进程模型).
///
/// Every spawned agent CLI is put in its own process group and recorded in
/// `process-groups.json` (atomic write, 0600) so that a bridge crash leaves
/// a recoverable ledger. At startup `reapOrphans(from:)` walks the ledger:
/// groups that are still alive get SIGTERM, up to 3 seconds (polled every
/// 100 ms), then SIGKILL; the file is cleared afterwards. `drain` performs
/// the same escalation for one live child during a normal shutdown.
public final class ProcessGroups: @unchecked Sendable {

    public struct Entry: Codable, Equatable {
        public var label: String
        public var pgid: pid_t

        public init(label: String, pgid: pid_t) {
            self.label = label
            self.pgid = pgid
        }
    }

    public static let fileName = "process-groups.json"

    private let directory: URL
    private let queue = DispatchQueue(label: "genius-coder.processgroups")

    public init(directory: URL) {
        self.directory = directory
    }

    /// Location of the ledger file for this instance's directory.
    public var fileURL: URL {
        directory.appendingPathComponent(Self.fileName)
    }

    // MARK: - Ledger

    /// Insert or replace the entry for `label`, persisting atomically.
    public func record(label: String, pgid: pid_t) {
        queue.sync {
            var entries = Self.load(from: directory)
            entries.removeAll { $0.label == label }
            entries.append(Entry(label: label, pgid: pgid))
            Self.write(entries, to: directory)
        }
    }

    /// Drop the entry for a cleanly-drained child.
    public func forget(label: String) {
        queue.sync {
            var entries = Self.load(from: directory)
            let before = entries.count
            entries.removeAll { $0.label == label }
            guard entries.count != before else { return }
            Self.write(entries, to: directory)
        }
    }

    // MARK: - Startup reap

    /// Terminate every still-live group recorded in `directory`'s ledger,
    /// then clear the file. Safe against our own process group (skipped).
    public func reapOrphans(from directory: URL) {
        queue.sync {
            let entries = Self.load(from: directory)
            for entry in entries {
                // Never signal ourselves or a nonsense id.
                guard entry.pgid > 1, entry.pgid != getpgrp() else {
                    BridgeLog.net.error("skip suspicious pgid \(entry.pgid) for \(entry.label, privacy: .public)")
                    continue
                }
                guard Self.groupAlive(entry.pgid) else {
                    BridgeLog.net.info("orphan group \(entry.label, privacy: .public) already gone (pgid \(entry.pgid))")
                    continue
                }
                kill(-entry.pgid, SIGTERM)
                BridgeLog.net.info("orphan group \(entry.label, privacy: .public) SIGTERM (pgid \(entry.pgid))")
                let deadline = Date().addingTimeInterval(3.0)
                while Date() < deadline, Self.groupAlive(entry.pgid) {
                    usleep(100_000)
                }
                if Self.groupAlive(entry.pgid) {
                    kill(-entry.pgid, SIGKILL)
                    BridgeLog.net.error("orphan group \(entry.label, privacy: .public) SIGKILL (pgid \(entry.pgid))")
                } else {
                    BridgeLog.net.info("orphan group \(entry.label, privacy: .public) terminated")
                }
            }
            let url = directory.appendingPathComponent(Self.fileName)
            try? FileManager.default.removeItem(at: url)
            BridgeLog.net.info("process group ledger cleared (\(entries.count) entries)")
        }
    }

    // MARK: - Live drain

    /// Escalating shutdown of one child: SIGTERM its process group, poll for
    /// up to 3 seconds, then SIGKILL (group, falling back to the direct pid
    /// when the child is not a group leader). Reaps the Process on return.
    public func drain(process: Process, label: String) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        if process.isRunning {
            Self.signalGroupThenProcess(pid, SIGTERM)
            BridgeLog.net.info("drain \(label, privacy: .public) SIGTERM (pid \(pid))")
            let deadline = Date().addingTimeInterval(3.0)
            while Date() < deadline, process.isRunning {
                usleep(100_000)
            }
            if process.isRunning {
                Self.signalGroupThenProcess(pid, SIGKILL)
                BridgeLog.net.error("drain \(label, privacy: .public) SIGKILL (pid \(pid))")
            }
        }
        process.waitUntilExit()
        BridgeLog.net.info("drained \(label, privacy: .public)")
    }

    // MARK: - Internals

    /// A group is alive if kill(0) succeeds, or exists-but-foreign (EPERM).
    private static func groupAlive(_ pgid: pid_t) -> Bool {
        if kill(-pgid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Signal the group; when the child is not a group leader (no group
    /// with that id exists) fall back to signalling the pid itself.
    private static func signalGroupThenProcess(_ pid: pid_t, _ signal: Int32) {
        if kill(-pid, signal) == -1, errno == ESRCH {
            kill(pid, signal)
        }
    }

    static func load(from directory: URL) -> [Entry] {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }

    /// Atomic write: encode, write to a temp sibling, chmod 0600, rename(2)
    /// over the destination.
    static func write(_ entries: [Entry], to directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        let url = directory.appendingPathComponent(fileName)
        let temp = directory.appendingPathComponent(fileName + ".tmp-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            // rename(2) atomically replaces an existing destination.
            let rc = rename(temp.path, url.path)
            if rc != 0 {
                BridgeLog.net.error("process group ledger rename failed (errno \(errno))")
                try? FileManager.default.removeItem(at: temp)
            }
        } catch {
            BridgeLog.net.error("process group ledger write failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: temp)
        }
    }
}
