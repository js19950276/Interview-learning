import Foundation
import PhoneProtocol

/// The allowlist persisted as `allowlist.json` in Application Support.
/// Roots must be canonical absolute directories; matching is by path
/// component, never by string prefix (spec: Indexer → 允许列表).
public struct Allowlist: Codable, Equatable {
    public var roots: [String]
    public var allowRoot: Bool
    public var seededFromSessions: Bool
    public var seedPromptAnswered: Bool

    public init(
        roots: [String] = [],
        allowRoot: Bool = false,
        seededFromSessions: Bool = false,
        seedPromptAnswered: Bool = false
    ) {
        self.roots = roots
        self.allowRoot = allowRoot
        self.seededFromSessions = seededFromSessions
        self.seedPromptAnswered = seedPromptAnswered
    }

    public static func load(from directory: URL) -> Allowlist {
        let url = directory.appendingPathComponent("allowlist.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Allowlist.self, from: data) else {
            return Allowlist()
        }
        return decoded
    }

    public func save(to directory: URL) {
        let url = directory.appendingPathComponent("allowlist.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Validate and normalize a user- or seed-provided root.
    /// Relative paths are rejected; "/" is rejected unless explicitly allowed.
    public static func normalizeRoot(_ candidate: String, explicitRootAllowed: Bool) -> String? {
        guard candidate.hasPrefix("/") else { return nil }
        let canonical = CanonicalPath.canonicalize(cwd: candidate).path
        if canonical == "/" && !explicitRootAllowed { return nil }
        return canonical
    }

    /// Component-wise containment: `/Users/me/code` covers
    /// `/Users/me/code/repo` but NOT `/Users/me/code-evil` or
    /// `/Users/me/code.bak`.
    public func matches(canonicalPath: String) -> Bool {
        if allowRoot { return true }
        return roots.contains { CanonicalPath.isDescendant(of: $0, candidate: canonicalPath) }
    }

    /// Whether a project row (canonical path) may be surfaced at all.
    public func permits(canonicalPath: String) -> Bool {
        matches(canonicalPath: canonicalPath)
    }
}

/// One-shot first-launch seeding prompt state machine (spec: Indexer).
/// Seeds canonical cwds seen in Codex/Grok/dsh stores after a single
/// confirmation; a refusal leaves roots empty and never asks again.
public struct AllowlistSeeder {
    public init() {}

    public func candidateRoots(from conversations: [(cwd: String, agent: AgentKind)]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in conversations {
            guard entry.agent != .claude else { continue } // Claude never seeds (no fixture)
            let canonical = CanonicalPath.canonicalize(cwd: entry.cwd).path
            // Container cwds that do not exist on this Mac never seed.
            guard FileManager.default.fileExists(atPath: canonical) else { continue }
            guard canonical != "/" else { continue }
            if seen.insert(canonical).inserted {
                ordered.append(canonical)
            }
        }
        return ordered.sorted()
    }

    public func applyConfirmation(_ current: Allowlist, roots: [String]) -> Allowlist {
        var next = current
        next.roots = roots
        next.seededFromSessions = true
        next.seedPromptAnswered = true
        return next
    }

    public func applyRefusal(_ current: Allowlist) -> Allowlist {
        var next = current
        next.roots = []
        next.seededFromSessions = false
        next.seedPromptAnswered = true
        return next
    }
}
