import Foundation

/// Canonical project path (spec: Indexer → 规范路径).
///
///     real = realpath(cwd), strip trailing "/" but keep "/"
///     top  = git -C real rev-parse --show-toplevel  (500ms timeout)
///     if top succeeds and is an ancestor of real: realpath(top)
///     else: real
public enum CanonicalPath {
    public static func realpath(_ path: String) -> String {
        guard let result = path.withCString({ Darwin.realpath($0, nil) }) else {
            // Missing path: normalize lexically, mark missing downstream.
            return lexicallyNormalized(path)
        }
        defer { free(result) }
        let s = String(cString: result)
        guard s != "/" else { return "/" }
        return String(s.dropLast(s.hasSuffix("/") && s.count > 1 ? 1 : 0))
    }

    static func lexicallyNormalized(_ path: String) -> String {
        var components = path.split(separator: "/").map(String.init)
        var out: [String] = []
        for c in components {
            if c == "." { continue }
            if c == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(c)
        }
        let joined = "/" + out.joined(separator: "/")
        return joined == "/" ? "/" : joined
    }

    /// `candidate` is inside `root` when equal, or root is a proper path-prefix
    /// component (never a string prefix).
    public static func isDescendant(of root: String, candidate: String) -> Bool {
        if root == candidate { return true }
        guard root.hasSuffix("/") == false else { return false }
        return candidate.hasPrefix(root + "/")
    }

    public static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        isDescendant(of: ancestor, candidate: path)
    }

    /// Full canonicalization including the git toplevel promotion.
    public static func canonicalize(cwd: String) -> (path: String, missing: Bool) {
        let real = realpath(cwd)
        let exists = FileManager.default.fileExists(atPath: real)
        guard exists else { return (real, true) }
        if let top = gitToplevel(of: real), isAncestor(top, of: real) {
            return (realpath(top), false)
        }
        return (real, false)
    }

    static func gitToplevel(of directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory, "rev-parse", "--show-toplevel"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // 500ms budget; kill over-budget runs.
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0,
              let data = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile(),
              let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty else {
            return nil
        }
        return out
    }
}

/// Memoized, concurrency-friendly canonicalizer. Git subprocesses dominate
/// cold-index cost, so each unique cwd is resolved once and reads hit the
/// cache (spec: cold index < 2 s, warm queries < 1 s).
public final class CanonicalPathCache {
    public static let shared = CanonicalPathCache()

    private var lock = NSLock()
    private var cache: [String: (path: String, missing: Bool)] = [:]
    private let workQueue = DispatchQueue(label: "genius-coder.canonical", attributes: .concurrent)

    public init() {}

    public func canonicalize(cwd: String) -> (path: String, missing: Bool) {
        lock.lock()
        if let hit = cache[cwd] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let result = CanonicalPath.canonicalize(cwd: cwd)
        lock.lock()
        cache[cwd] = result
        lock.unlock()
        return result
    }

    /// Resolve many cwds concurrently (git subprocesses serialize badly).
    public func canonicalizeBatch(_ cwds: [String]) -> [String: (path: String, missing: Bool)] {
        let unique = Array(Set(cwds))
        let group = DispatchGroup()
        for cwd in unique {
            group.enter()
            workQueue.async { [weak self] in
                defer { group.leave() }
                _ = self?.canonicalize(cwd: cwd)
            }
        }
        group.wait()
        lock.lock()
        let out = cache.filter { unique.contains($0.key) }
        lock.unlock()
        return out
    }

    public func canonicalPath(_ cwd: String) -> String {
        canonicalize(cwd: cwd).path
    }
}
