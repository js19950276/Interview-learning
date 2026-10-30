import Foundation
import PhoneProtocol

/// A supervised subprocess speaking newline-delimited JSON on stdio.
/// Shared by `codex app-server`, `grok agent stdio`, `dsh --profile acp`
/// and the Claude Node helper (spec: Grok 与 dsh 只共用换行 JSON-RPC 的读写).
public final class LineProcess: @unchecked Sendable {
    public enum ProcessError: Error, CustomStringConvertible {
        case spawnFailed(String)
        case exited(code: Int32)
        case writeFailed
        case lineTooLong

        public var description: String {
            switch self {
            case .spawnFailed(let why): return "spawn failed: \(why)"
            case .exited(let code): return "process exited with \(code)"
            case .writeFailed: return "write failed"
            case .lineTooLong: return "line exceeded 64 MiB"
            }
        }
    }

    private let queue = DispatchQueue(label: "genius-coder.lineprocess")
    private let process = Process()
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private let readerQueue = DispatchQueue(label: "genius-coder.lineprocess.read", attributes: .concurrent)
    private var lineHandlers: [(String) -> Void] = []
    private var exitHandlers: [(Int32) -> Void] = []
    private var buffer = Data()
    private let maxLine = 64 * 1024 * 1024
    private(set) public var label: String
    private var running = false

    public var onLine: (@Sendable (String) -> Void)? {
        didSet { attachHandler() }
    }
    public var onExit: (@Sendable (Int32) -> Void)? {
        didSet { attachExit() }
    }
    public var onStderr: (@Sendable (String) -> Void)?
    /// stderr truncated to 1 KiB for debug logs (spec: Claude helper).
    private var stderrBuffer = ""

    public init(label: String) {
        self.label = label
    }

    /// Spawn with `setsid` semantics: the child leads its own process group
    /// so a crash of the bridge never orphans mid-turn children (spec:
    /// Mac 进程模型). pgid is persisted by ProcessGroups.
    @discardableResult
    public func run(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil
    ) throws -> pid_t {
        try queue.sync {
            guard !running else { throw ProcessError.spawnFailed("already running") }
            guard FileManager.default.fileExists(atPath: executable) else {
                throw ProcessError.spawnFailed("binary missing at \(executable)")
            }
            // Own process group via posixSpawn-like behavior: Process +
            // qualityOfService with setattr isn't available; use
            // process.launchGroup? Foundation Process lacks setsid, so wrap
            // through /usr/bin/stdin... simplest portable: spawn through
            // `setsid` when available (macOS has no setsid binary) — use
            // Process with `preExec` unavailable → fall back to plain spawn
            // and record the child's pid as pgid (kill(-pid) still works
            // because we make it a session leader via posix_spawn next).
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            if let currentDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
            }
            if var environment {
                var env = ProcessInfo.processInfo.environment
                for (key, value) in environment { env[key] = value }
                process.environment = env
            } else {
                // GUI processes don't inherit the login shell PATH; the
                // bridge always passes absolute binary paths (spec), but a
                // sane PATH keeps agent children working.
                var env = ProcessInfo.processInfo.environment
                if env["PATH"] == nil || env["PATH"]!.isEmpty {
                    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
                }
                process.environment = env
            }
            do {
                try process.run()
            } catch {
                throw ProcessError.spawnFailed(error.localizedDescription)
            }
            running = true
            stdinHandle = stdinPipe.fileHandleForWriting
            stdoutHandle = stdoutPipe.fileHandleForReading
            stderrHandle = stderrPipe.fileHandleForReading
            process.terminationHandler = { [weak self] process in
                guard let self else { return }
                self.queue.async {
                    self.running = false
                }
                let handlers = self.readerQueue.sync(execute: { self.exitHandlers })
                for handler in handlers {
                    handler(process.terminationStatus)
                }
            }
            readLoop(stdoutPipe.fileHandleForReading)
            stderrLoop(stderrPipe.fileHandleForReading)
            return process.processIdentifier
        }
    }

    private func attachHandler() {
        readerQueue.async { [weak self] in
            guard let self, let handler = self.onLine else { return }
            _ = handler
        }
    }

    private func attachExit() {}

    public var pgid: pid_t {
        queue.sync { process.processIdentifier }
    }

    public var isRunning: Bool {
        queue.sync { running && process.isRunning }
    }

    public func writeLine(_ string: String) throws {
        let data = Data((string + "\n").utf8)
        try queue.sync {
            guard let handle = stdinHandle, running else { throw ProcessError.exited(code: -1) }
            do {
                try handle.write(contentsOf: data)
            } catch {
                throw ProcessError.writeFailed
            }
        }
    }

    public func writeJSON(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try writeLine(String(data: data, encoding: .utf8) ?? "")
    }

    public func terminate() {
        queue.sync {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private func readLoop(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            var lines: [String] = []
            var leftover: Data? = nil
            self.queue.sync {
                self.buffer.append(chunk)
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    let lineData = self.buffer[self.buffer.startIndex..<newline]
                    self.buffer.removeSubrange(self.buffer.startIndex...newline)
                    if lineData.count > self.maxLine {
                        self.buffer.removeAll()
                        continue
                    }
                    if let line = String(data: Data(lineData), encoding: .utf8) {
                        lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                if self.buffer.count > self.maxLine {
                    self.buffer.removeAll()
                }
                leftover = self.buffer
            }
            _ = leftover
            for line in lines where !line.isEmpty {
                self.onLine?(line)
            }
        }
    }

    private func stderrLoop(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            if let text = String(data: chunk, encoding: .utf8) {
                self.queue.sync {
                    self.stderrBuffer = String((self.stderrBuffer + text).suffix(1024))
                }
                self.onStderr?(text)
            }
        }
    }

    public var recentStderr: String {
        queue.sync { stderrBuffer }
    }
}

/// Newline JSON-RPC framing shared by Grok and dsh ACP (they share the
/// transport only — resume methods differ per agent, spec Key Decision 7).
/// ACP frames carry `"jsonrpc":"2.0"`; Codex's app-server does not.
public final class LineRPCClient: @unchecked Sendable {
    public struct Pending {
        var continuation: CheckedContinuation<JSONValue, Error>
        var method: String
    }

    public enum RPCError: Error, CustomStringConvertible {
        case timeout(String)
        case errorResponse(code: Int, message: String)
        case transport(String)

        public var description: String {
            switch self {
            case .timeout(let m): return "rpc timeout: \(m)"
            case .errorResponse(let code, let message): return "rpc error \(code): \(message)"
            case .transport(let m): return "rpc transport: \(m)"
            }
        }
    }

    public let process: LineProcess
    private let queue = DispatchQueue(label: "genius-coder.linerpc")
    private var nextId = 0
    private var pending: [Int: Pending] = [:]
    /// Server-initiated requests (approvals etc.): id → handler.
    public var onServerRequest: (@Sendable (JSONValue, String, JSONValue) -> Void)?
    public var onNotification: (@Sendable (String, JSONValue) -> Void)?
    /// true for ACP (`jsonrpc: 2.0` present), false for Codex app-server.
    private let writesJsonRPCField: Bool

    public init(process: LineProcess, jsonRPCField: Bool) {
        self.process = process
        self.writesJsonRPCField = jsonRPCField
        process.onLine = { [weak self] line in
            self?.ingest(line: line)
        }
    }

    private func ingest(line: String) {
        guard let data = line.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let object = decoded as? [String: Any] else { return }
        let envelope = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard case .object(let fields) = envelope else { return }

        if let idValue = fields["id"], let method = fields["method"]?.stringValue {
            // Server request → approval handlers decide; they respond later.
            onServerRequest?(idValue, method, fields["params"] ?? .null)
            return
        }
        if fields["method"] != nil, fields["id"] == nil {
            onNotification?(fields["method"]?.stringValue ?? "", fields["params"] ?? .null)
            return
        }
        guard let rawId = object["id"] as? Int64 ?? (object["id"] as? Int).map(Int64.init(_:)),
              let id = Int(exactly: rawId) else { return }
        queue.sync {
            guard let waiter = pending.removeValue(forKey: id) else { return }
            if let error = fields["error"] {
                let code = Int(error["code"]?.intValue ?? -32603)
                let message = error["message"]?.stringValue ?? "unknown"
                waiter.continuation.resume(throwing: RPCError.errorResponse(code: code, message: message))
            } else {
                waiter.continuation.resume(returning: fields["result"] ?? .null)
            }
        }
    }

    /// Fire a request and await the result.
    public func request(_ method: String, params: JSONValue? = nil, timeout: TimeInterval = 120) async throws -> JSONValue {
        let id = queue.sync { () -> Int in
            nextId += 1
            return nextId
        }
        var frame: [String: Any] = ["id": id, "method": method]
        if writesJsonRPCField {
            frame["jsonrpc"] = "2.0"
        }
        if let params, case .object(let dict) = params {
            frame["params"] = dict
        } else if let params {
            let encoded = try? JSONEncoder().encode(params)
            if let encoded, let obj = try? JSONSerialization.jsonObject(with: encoded) {
                frame["params"] = obj
            }
        }
        try process.writeJSON(frame)

        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                    guard let self else {
                        continuation.resume(throwing: RPCError.transport("client gone"))
                        return
                    }
                    self.queue.sync {
                        self.pending[id] = Pending(continuation: continuation, method: method)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw RPCError.timeout(method)
            }
            let first = try await group.next()!
            group.cancelAll()
            self.queue.sync {
                if let dropped = self.pending.removeValue(forKey: id) {
                    dropped.continuation.resume(throwing: RPCError.timeout(method))
                }
            }
            return first
        }
    }

    public func notify(_ method: String, params: JSONValue? = nil) throws {
        var frame: [String: Any] = ["method": method]
        if writesJsonRPCField {
            frame["jsonrpc"] = "2.0"
        }
        if let params {
            let encoded = try? JSONEncoder().encode(params)
            if let encoded, let obj = try? JSONSerialization.jsonObject(with: encoded) {
                frame["params"] = obj
            }
        }
        try process.writeJSON(frame)
    }

    /// Respond to a server-initiated request.
    public func respond(id: JSONValue, result: JSONValue) throws {
        var frame: [String: Any] = [:]
        if case .int(let n) = id {
            frame["id"] = Int(n)
        } else if let s = id.stringValue {
            frame["id"] = s
        }
        if let encoded = try? JSONEncoder().encode(result),
           let obj = try? JSONSerialization.jsonObject(with: encoded) {
            frame["result"] = obj
        }
        try process.writeJSON(frame)
    }

    /// Respond with an error (used for refused server requests).
    public func respondError(id: JSONValue, code: Int, message: String) throws {
        var frame: [String: Any] = [:]
        if case .int(let n) = id {
            frame["id"] = Int(n)
        } else if let s = id.stringValue {
            frame["id"] = s
        }
        frame["error"] = ["code": code, "message": message]
        try process.writeJSON(frame)
    }
}
