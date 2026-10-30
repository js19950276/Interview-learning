import Foundation
import SQLite3
import PhoneProtocol

/// Aggregates the four agent stores into the project → conversation index,
/// applies the allowlist and persists a cache (`index.sqlite`).
///
/// Personal scale: a full rescan reads metadata only and stays well under
/// the 2 s cold / 1 s warm budgets (spec: Indexer).
public final class IndexStore: @unchecked Sendable {
    public struct Snapshot {
        public var projects: [IndexedProject]
        public var conversations: [IndexedConversation]
        public var projectIdByPath: [String: String]
        /// conversationId → projectId, resolved once at snapshot build.
        public var projectIdByConversation: [String: String]
        public var indexedAt: Int64

        public init(projects rows: [IndexedConversation], indexedAt: Int64, cache: CanonicalPathCache = .shared) {
            // Resolve every unique cwd once, concurrently (git subprocesses
            // dominate cold-index cost otherwise).
            let canonical = cache.canonicalizeBatch(rows.map(\.cwd))
            // Build projects from top-level rows only; subagents inherit
            // their parent's project and never create one (container cwds
            // like /root/... do not exist on this Mac).
            var byPath: [String: IndexedProject] = [:]
            for row in rows where row.parentNativeId == nil && !row.cwd.isEmpty {
                guard let (canonicalPath, missing) = canonical[row.cwd] else { continue }
                guard canonicalPath != "/" else { continue }
                if byPath[canonicalPath] == nil {
                    byPath[canonicalPath] = IndexedProject(canonicalPath: canonicalPath, missing: missing)
                }
                // Grok: when git_root_dir is an ancestor the project key is
                // the git root — handled by canonicalize's git promotion.
            }
            var projectList = Array(byPath.values)
            projectList.sort { $0.canonicalPath < $1.canonicalPath }
            self.projects = projectList
            self.conversations = rows
            self.projectIdByPath = Dictionary(uniqueKeysWithValues: projectList.map { ($0.canonicalPath, $0.projectId) })
            var byConversation: [String: String] = [:]
            var cwdByNative: [String: String] = [:]
            for row in rows {
                cwdByNative[row.agent.rawValue + ":" + row.nativeId] = row.cwd
            }
            for row in rows {
                var pid: String? = nil
                if let parent = row.parentNativeId,
                   let parentCwd = cwdByNative[row.agent.rawValue + ":" + parent],
                   let (parentCanonical, _) = canonical[parentCwd] {
                    pid = projectIdByPath[parentCanonical]
                } else if !row.cwd.isEmpty, let (rowCanonical, _) = canonical[row.cwd] {
                    pid = projectIdByPath[rowCanonical]
                }
                if let pid {
                    byConversation[row.conversationId] = pid
                }
            }
            self.projectIdByConversation = byConversation
            self.indexedAt = indexedAt
        }
    }

    private let queue = DispatchQueue(label: "genius-coder.indexstore")
    private var snapshot: Snapshot
    private var allowlist: Allowlist
    private let cacheURL: URL
    private let indexers: [AgentIndexer]
    private var db: OpaquePointer?

    public init(
        appSupportDirectory: URL,
        allowlist: Allowlist,
        indexers: [AgentIndexer] = [
            CodexIndex(),
            GrokIndex(),
            ClaudeIndex(),
            DshIndex(),
        ]
    ) {
        self.allowlist = allowlist
        self.cacheURL = appSupportDirectory.appendingPathComponent("index.sqlite")
        self.indexers = indexers
        self.snapshot = Snapshot(projects: [], indexedAt: 0)
        try? FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        openCache()
        loadFromCache()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public var currentIndexedAt: Int64 {
        queue.sync { snapshot.indexedAt }
    }

    public func updateAllowlist(_ allowlist: Allowlist) {
        queue.sync {
            self.allowlist = allowlist
        }
    }

    // MARK: scanning

    /// Full rescan: read-only metadata from every store, filtered by the
    /// allowlist, then written through to the sqlite cache.
    public func refresh() {
        let allowlistCopy = queue.sync { allowlist }
        var all: [IndexedConversation] = []
        for indexer in indexers {
            all.append(contentsOf: indexer.scan())
        }
        let built = Snapshot(projects: all, indexedAt: Int64(Date().timeIntervalSince1970 * 1000))
        queue.sync {
            snapshot = built
            persist(allowlist: allowlistCopy, snapshot: built)
        }
        BridgeLog.index.info("index refreshed: \(built.projects.count) projects, \(built.conversations.count) conversations")
    }

    // MARK: queries

    public func projects(filter: AgentFilter) -> [ProjectSummary] {
        queue.sync {
            let rows = snapshot.conversations
            var pathByPid = Dictionary(uniqueKeysWithValues: snapshot.projectIdByPath.map { ($0.value, $0.key) })
            var projectHasRow: [String: [AgentKind: Int]] = [:]
            for row in rows {
                guard let pid = snapshot.projectIdByConversation[row.conversationId] else { continue }
                let allowed = allowlist.permits(canonicalPath: pathByPid[pid] ?? "")
                guard allowed else { continue }
                projectHasRow[pid, default: [:]][row.agent, default: 0] += 1
            }
            var summaries: [ProjectSummary] = []
            for project in snapshot.projects {
                guard allowlist.permits(canonicalPath: project.canonicalPath) else { continue }
                let agentCounts = projectHasRow[project.projectId] ?? [:]
                if let only = filter.agent, (agentCounts[only] ?? 0) == 0 {
                    // Filtered agent with no top-level sessions: hide project.
                    continue
                }
                let counts = Dictionary(uniqueKeysWithValues: agentCounts.map { ($0.key.rawValue, $0.value) })
                summaries.append(ProjectSummary(
                    projectId: project.projectId,
                    canonicalPath: project.canonicalPath,
                    displayName: project.displayName,
                    missing: project.missing,
                    counts: counts
                ))
            }
            // Empty projects only from the allowlist roots themselves, and
            // only when nothing beneath a root already formed a project.
            if filter.agent == nil {
                for root in allowlist.roots {
                    let canonical = CanonicalPathCache.shared.canonicalPath(root)
                    guard allowlist.permits(canonicalPath: canonical),
                          snapshot.projectIdByPath[canonical] == nil else { continue }
                    let covered = snapshot.projects.contains {
                        CanonicalPath.isDescendant(of: canonical, candidate: $0.canonicalPath)
                    }
                    guard !covered else { continue }
                    summaries.append(ProjectSummary(
                        projectId: ProjectID(canonicalPath: canonical)?.rawValue ?? "proj_invalid",
                        canonicalPath: canonical,
                        displayName: URL(fileURLWithPath: canonical).lastPathComponent,
                        missing: !FileManager.default.fileExists(atPath: canonical),
                        counts: [:]
                    ))
                }
            }
            return summaries
        }
    }

    public func conversations(projectId: String, filter: AgentFilter, limit: Int) -> [ConversationSummary] {
        let cap = min(max(1, limit), 100)
        return queue.sync {
            var out: [ConversationSummary] = []
            for row in snapshot.conversations {
                // Subagents live under their parent, never as top-level rows.
                guard row.parentNativeId == nil else { continue }
                guard let pid = snapshot.projectIdByConversation[row.conversationId], pid == projectId else { continue }
                if let only = filter.agent, row.agent != only { continue }
                out.append(ConversationSummary(
                    conversationId: row.conversationId,
                    agent: row.agent,
                    projectId: pid,
                    title: row.title,
                    updatedAt: row.updatedAt,
                    archived: row.archived,
                    resumable: row.resumable,
                    resumableError: row.resumableError,
                    parentConversationId: nil,
                    detail: row.emptyHistory ? PhoneErrorCode.emptyHistory.rawValue : nil
                ))
            }
            out.sort { $0.updatedAt > $1.updatedAt }
            return Array(out.prefix(cap))
        }
    }

    /// Children of a conversation (subagent rows), for expandable sections.
    public func children(of conversationId: String) -> [ConversationSummary] {
        queue.sync {
            guard let cid = ConversationID(rawValue: conversationId) else { return [] }
            return snapshot.conversations
                .filter { $0.agent == cid.agent && $0.parentNativeId == cid.nativeID }
                .map { row in
                    ConversationSummary(
                        conversationId: row.conversationId,
                        agent: row.agent,
                        projectId: "",
                        title: row.title,
                        updatedAt: row.updatedAt,
                        archived: row.archived,
                        resumable: false,
                        resumableError: row.resumableError,
                        parentConversationId: conversationId
                    )
                }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    public func conversation(_ id: ConversationID) -> IndexedConversation? {
        queue.sync {
            snapshot.conversations.first { $0.conversationId == id.rawValue }
        }
    }

    /// Raw cwds seen across stores, used by the one-shot allowlist seeder.
    public func knownCwds() -> [(cwd: String, agent: AgentKind)] {
        queue.sync {
            snapshot.conversations.map { ($0.cwd, $0.agent) }
        }
    }

    // MARK: sqlite cache

    private func openCache() {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(cacheURL.path, &db, flags, nil) == SQLITE_OK else {
            BridgeLog.index.error("cannot open index cache")
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS projects (
            project_id TEXT PRIMARY KEY,
            canonical_path TEXT UNIQUE NOT NULL,
            display_name TEXT NOT NULL,
            missing INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS conversations (
            conversation_id TEXT PRIMARY KEY,
            agent TEXT NOT NULL,
            native_id TEXT NOT NULL,
            cwd TEXT NOT NULL,
            title TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            archived INTEGER NOT NULL,
            resumable INTEGER NOT NULL,
            resumable_error TEXT,
            parent_native_id TEXT,
            source_path TEXT,
            empty_history INTEGER NOT NULL DEFAULT 0
        );
        """)
    }

    private func loadFromCache() {
        guard let db else { return }
        var rows: [IndexedConversation] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT conversation_id, agent, native_id, cwd, title, updated_at,
                   archived, resumable, resumable_error, parent_native_id, source_path, empty_history
            FROM conversations
            """, -1, &stmt, nil) == SQLITE_OK else {
            BridgeLog.index.error("cache select prepare failed: \(db != nil ? String(cString: sqlite3_errmsg(db)) : "no db")")
            return
        }
        defer { sqlite3_finalize(stmt) }
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            let agent = String(cString: sqlite3_column_text(stmt, 1))
            if let kind = AgentKind(rawValue: agent) {
                var row = IndexedConversation(
                    agent: kind,
                    nativeId: String(cString: sqlite3_column_text(stmt, 2)),
                    cwd: String(cString: sqlite3_column_text(stmt, 3)),
                    title: String(cString: sqlite3_column_text(stmt, 4)),
                    updatedAt: sqlite3_column_int64(stmt, 5),
                    archived: sqlite3_column_int64(stmt, 6) == 1,
                    resumable: sqlite3_column_int64(stmt, 7) == 1,
                    resumableError: sqlite3_column_text(stmt, 8).map { String(cString: $0) },
                    parentNativeId: sqlite3_column_text(stmt, 9).map { String(cString: $0) },
                    sourcePath: sqlite3_column_text(stmt, 10).map { String(cString: $0) },
                    emptyHistory: sqlite3_column_int64(stmt, 11) == 1
                )
                row.conversationId = String(cString: sqlite3_column_text(stmt, 0))
                rows.append(row)
            }
            stepResult = sqlite3_step(stmt)
        }
        let snapshot = Snapshot(projects: rows, indexedAt: 0)
        queue.sync {
            self.snapshot = snapshot
        }
    }

    private func persist(allowlist: Allowlist, snapshot: Snapshot) {
        guard let db else { return }
        exec("BEGIN IMMEDIATE")
        exec("DELETE FROM conversations")
        exec("DELETE FROM projects")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT OR REPLACE INTO conversations
            (conversation_id, agent, native_id, cwd, title, updated_at, archived, resumable, resumable_error, parent_native_id, source_path, empty_history)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """, -1, &stmt, nil) == SQLITE_OK else {
            exec("ROLLBACK")
            return
        }
        defer { sqlite3_finalize(stmt) }
        for row in snapshot.conversations {
            sqlite3_reset(stmt)
            bindText(stmt, 1, row.conversationId)
            bindText(stmt, 2, row.agent.rawValue)
            bindText(stmt, 3, row.nativeId)
            bindText(stmt, 4, row.cwd)
            bindText(stmt, 5, row.title)
            sqlite3_bind_int64(stmt, 6, row.updatedAt)
            sqlite3_bind_int(stmt, 7, row.archived ? 1 : 0)
            sqlite3_bind_int(stmt, 8, row.resumable ? 1 : 0)
            bindText(stmt, 9, row.resumableError)
            bindText(stmt, 10, row.parentNativeId)
            bindText(stmt, 11, row.sourcePath)
            sqlite3_bind_int(stmt, 12, row.emptyHistory ? 1 : 0)
            sqlite3_step(stmt)
        }
        for project in snapshot.projects {
            exec("INSERT OR REPLACE INTO projects (project_id, canonical_path, display_name, missing) VALUES ('\(project.projectId)','\(project.canonicalPath.replacingOccurrences(of: "'", with: "''"))','\(project.displayName.replacingOccurrences(of: "'", with: "''"))',\(project.missing ? 1 : 0))")
        }
        exec("COMMIT")
    }

    /// Bind text with SQLITE_TRANSIENT: Swift's implicit String→C-string
    /// conversion produces a temporary buffer that dies at return, so
    /// SQLITE_STATIC (nil destructor) leaves sqlite holding a dangling
    /// pointer until step-time.
    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        value.withCString { cstr in
            _ = sqlite3_bind_text(stmt, index, cstr, -1, Self.sqlTransient)
        }
    }

    static let sqlTransient: sqlite3_destructor_type = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err {
            BridgeLog.index.error("sqlite: \(String(cString: err))")
            sqlite3_free(err)
        }
    }
}
