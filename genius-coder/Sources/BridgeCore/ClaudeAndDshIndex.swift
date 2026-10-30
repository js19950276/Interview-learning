import Foundation
import PhoneProtocol

/// Claude Code store indexer. Without a real `~/.claude/projects` fixture
/// the parser must not guess field names (spec Non-Goals): a missing
/// directory yields zero rows; files that appear before a fixture lands are
/// listed as `unavailable` with `claude_history_needs_fixture` and are NOT
/// merged into existing projects (no slug guessing).
public final class ClaudeIndex: AgentIndexer {
    public let agent = AgentKind.claude
    private let projectsRoot: String

    public init(projectsRoot: String = AgentBinaries.claudeProjects) {
        self.projectsRoot = projectsRoot
    }

    public func scan() -> [IndexedConversation] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectsRoot, isDirectory: &isDir), isDir.boolValue else {
            // Missing directory: zero rows, not an error.
            return []
        }
        // Directory exists but no redacted fixture has been vetted yet.
        // Every top-level .jsonl becomes an unavailable row keyed only by
        // its UUID; cwd stays empty so it can never join a project.
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsRoot) else { return [] }
        var rows: [IndexedConversation] = []
        for slug in projectDirs {
            let dir = (projectsRoot as NSString).appendingPathComponent(slug)
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let uuid = String(file.dropLast(6))
                let path = (dir as NSString).appendingPathComponent(file)
                rows.append(IndexedConversation(
                    agent: .claude,
                    nativeId: uuid,
                    cwd: "",
                    title: String(uuid.prefix(8)),
                    updatedAt: GrokIndex.mtime(path),
                    archived: false,
                    resumable: false,
                    resumableError: PhoneErrorCode.claudeHistoryNeedsFixture.rawValue,
                    parentNativeId: nil,
                    sourcePath: path,
                    emptyHistory: false
                ))
            }
        }
        BridgeLog.index.info("claude: \(rows.count) rows pending fixture")
        return rows
    }
}

/// DeepSeek Harness indexer: disk is authoritative.
/// Sessions live under `$DSH_HOME/sessions/<encoded-cwd>/session-<uuid>/`;
/// the projcache (`storages/session_projcache/sessions/session-<uuid>.json`)
/// carries identity.cwd, title and sessionListMetadata.lastPromptAt;
/// `storages/workspace.json` carries archivedSessionIds.
public final class DshIndex: AgentIndexer {
    public let agent = AgentKind.deepseek
    private let sessionsRoot: String
    private let projcacheDir: String
    private let workspaceJSON: String
    private let binaryPath: String

    /// Log format versions this bridge understands.
    public static let supportedVersions: Set<Int> = [4]

    public init(home: String = AgentBinaries.dshHome, binaries: AgentBinaries = AgentBinaries()) {
        self.sessionsRoot = home + "/sessions"
        self.projcacheDir = home + "/storages/session_projcache/sessions"
        self.workspaceJSON = home + "/storages/workspace.json"
        self.binaryPath = binaries.dsh
    }

    struct Projcache: Decodable {
        struct Row<T: Decodable>: Decodable {
            var ver: Int?
            var seq: Int?
            var val: T?
        }
        struct Identity: Decodable {
            var formatVersion: Int?
            var createdAt: Int64?
            var cwd: String?
        }
        struct SessionListVal: Decodable { var blank: Bool?; var lastPromptAt: Int64? }
        struct GoalVal: Decodable { var current: String? }
        struct UsageVal: Decodable {
            struct Totals: Decodable {
                var uncachedInputTokens: Int64?
                var outputTokens: Int64?
                var cacheReadTokens: Int64?
                var cacheWriteTokens: Int64?
            }
            var totals: Totals?
        }
        // title.val can be null or a string; keep raw for manual extraction.
        struct JSONBox: Decodable {
            var isNull: Bool = false
            var stringValue: String?
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if c.decodeNil() { isNull = true } else { stringValue = try? c.decode(String.self) }
            }
        }
        struct Record: Decodable {
            struct Rows: Decodable {
                var title: Row<JSONBox>?
                var sessionListMetadata: Row<SessionListVal>?
                var goal: Row<GoalVal>?
                var tokenUsage: Row<UsageVal>?
            }
            var identity: Identity?
            var rows: Rows?
        }
        var version: Int?
        var record: Record?
    }

    struct WorkspaceFile: Decodable {
        struct Global: Decodable {
            var archivedSessionIds: [String]?
        }
        var global: Global?
    }

    public func scan() -> [IndexedConversation] {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        let binaryExists = fm.fileExists(atPath: binaryPath)

        var archivedIds = Set<String>()
        if let data = try? Data(contentsOf: URL(fileURLWithPath: workspaceJSON)),
           let ws = try? decoder.decode(WorkspaceFile.self, from: data) {
            archivedIds = Set(ws.global?.archivedSessionIds ?? [])
        }

        var projcache: [String: Projcache.Record] = [:]
        if let files = try? fm.contentsOfDirectory(atPath: projcacheDir) {
            for file in files where file.hasSuffix(".json") {
                let path = (projcacheDir as NSString).appendingPathComponent(file)
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let cache = try? decoder.decode(Projcache.self, from: data),
                      let record = cache.record else { continue }
                let nativeId = String(file.dropLast(5))
                projcache[nativeId] = record
            }
        }

        var rows: [IndexedConversation] = []
        guard let encodedDirs = try? fm.contentsOfDirectory(atPath: sessionsRoot) else { return [] }
        var isDir: ObjCBool = false
        for encoded in encodedDirs {
            let cwdRoot = (sessionsRoot as NSString).appendingPathComponent(encoded)
            guard fm.fileExists(atPath: cwdRoot, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let sessionDirs = try? fm.contentsOfDirectory(atPath: cwdRoot) else { continue }
            for session in sessionDirs where session.hasPrefix("session-") {
                let dir = (cwdRoot as NSString).appendingPathComponent(session)
                guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
                let nativeId = session
                let logPath = (dir as NSString).appendingPathComponent("session.v4.jsonl.zstd")
                guard fm.fileExists(atPath: logPath) else { continue }

                let record = projcache[nativeId]
                let cwd = record?.identity?.cwd ?? "" // never guess from the dir name
                let formatVersion = record?.identity?.formatVersion
                let titleVal = record?.rows?.title?.val?.stringValue
                let lastPromptAt = record?.rows?.sessionListMetadata?.val?.lastPromptAt
                let createdAt = record?.identity?.createdAt

                let updatedAt = Self.updatedAt(lastPromptAt: lastPromptAt, createdAt: createdAt, logPath: logPath)

                var resumable = binaryExists
                var resumableError: String? = nil
                if let formatVersion, !Self.supportedVersions.contains(formatVersion) {
                    resumable = false
                    resumableError = PhoneErrorCode.unsupportedSessionVersion.rawValue
                } else if formatVersion == nil {
                    // No projcache at all: cannot verify the format version.
                    resumable = false
                    resumableError = PhoneErrorCode.sessionUnreadable.rawValue
                }

                rows.append(IndexedConversation(
                    agent: .deepseek,
                    nativeId: nativeId,
                    cwd: cwd,
                    title: Self.title(titleVal: titleVal, id: nativeId),
                    updatedAt: updatedAt,
                    archived: archivedIds.contains(nativeId),
                    resumable: resumable,
                    resumableError: resumableError,
                    parentNativeId: nil,
                    sourcePath: logPath,
                    emptyHistory: false
                ))
            }
        }
        BridgeLog.index.info("dsh: indexed \(rows.count) sessions")
        return rows
    }

    static func title(titleVal: String?, id: String) -> String {
        if let t = titleVal, !t.isEmpty { return t }
        return String(id.dropFirst("session-".count).prefix(8))
    }

    static func updatedAt(lastPromptAt: Int64?, createdAt: Int64?, logPath: String) -> Int64 {
        if let lastPromptAt, lastPromptAt > 0 { return lastPromptAt }
        if let createdAt, createdAt > 0 { return createdAt }
        return GrokIndex.mtime(logPath)
    }
}
