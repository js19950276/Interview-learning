import Foundation
import Darwin

/// Reference-counted sleep prevention during turns (spec: caffeinate).
///
/// `beginTurn()` / `endTurnIfNeeded()` may be called from any thread or
/// queue. The first begin spawns `/usr/bin/caffeinate -im -w <bridge pid>`
/// once; caffeinate dies by itself if the bridge crashes (`-w`), so no
/// stale sleep-preventer can outlive the process. When the count returns
/// to zero the child gets SIGTERM (then SIGKILL after a 1s grace).
/// Spawn and exit are logged via `BridgeLog.net`.
public final class Caffeinate: @unchecked Sendable {

    /// Abstract handle over the spawned helper so tests can inject a fake
    /// instead of launching a real process.
    public protocol Handle: AnyObject {
        /// Best-effort terminate; must be safe to call more than once.
        func shutdown()
    }

    public static let executablePath = "/usr/bin/caffeinate"

    private let queue = DispatchQueue(label: "genius-coder.caffeinate")
    private let spawner: (String, [String]) -> Handle?
    private var activeCount = 0
    private var handle: Handle?

    /// - Parameters:
    ///   - spawner: invoked as `spawner(executablePath, arguments)` when the
    ///     count goes 0 -> 1. The default spawns the real caffeinate binary.
    public init(spawner: ((String, [String]) -> Handle?)? = nil) {
        if let spawner {
            self.spawner = spawner
        } else {
            self.spawner = { executable, arguments in
                ProcessHandle(executable: executable, arguments: arguments)
            }
        }
    }

    /// Mark a turn as started; spawns the helper on 0 -> 1.
    public func beginTurn() {
        queue.sync {
            activeCount += 1
            guard activeCount == 1 else { return }
            handle = spawner(Self.executablePath, Self.defaultArguments(bridgePID: getpid()))
            if handle != nil {
                BridgeLog.net.info("caffeinate spawned for turn (args -im -w)")
            } else {
                BridgeLog.net.error("caffeinate spawn failed; sleep prevention inactive this turn")
            }
        }
    }

    /// Mark a turn as finished; terminates the helper when the count hits 0.
    /// Clamped at zero: extra calls are harmless.
    public func endTurnIfNeeded() {
        queue.sync {
            guard activeCount > 0 else { return }
            activeCount -= 1
            guard activeCount == 0 else { return }
            handle?.shutdown()
            handle = nil
            BridgeLog.net.info("caffeinate turn ended")
        }
    }

    /// Current nesting depth (0 = idle, no helper running).
    public var activeTurnCount: Int {
        queue.sync { activeCount }
    }

    /// `-im -w <pid>`: keep the Mac awake (idle + disk) while the bridge pid
    /// lives, without holding a display assertion.
    public static func defaultArguments(bridgePID: pid_t) -> [String] {
        ["-im", "-w", String(bridgePID)]
    }
}

/// Real `Process`-backed helper used by the default spawner.
final class ProcessHandle: Caffeinate.Handle {
    private let process: Process

    init(executable: String, arguments: [String]) {
        process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Silence output; caffeinate is quiet anyway.
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            BridgeLog.net.error("caffeinate run failed: \(error.localizedDescription)")
        }
    }

    func shutdown() {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        kill(pid, SIGTERM)
        BridgeLog.net.info("caffeinate SIGTERM sent")
        // Reap off the caller's thread; escalate to SIGKILL after 1s.
        DispatchQueue.global().async { [process] in
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline, kill(pid, 0) == 0 {
                usleep(50_000)
            }
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
            process.waitUntilExit()
            BridgeLog.net.info("caffeinate exited")
        }
    }
}
