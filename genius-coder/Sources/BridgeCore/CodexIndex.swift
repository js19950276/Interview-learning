import Foundation
import SQLite3
import PhoneProtocol

/// Reads `~/.codex/state_5.sqlite` (`threads` + `thread_spawn_edges`) as
/// metadata-only. Opening is done through a read-only immutable URI; when
/// that fails (WAL sidecars on locked stores) the database is copied to a
/// scratch location first. Never reads `thread_history_1.sqlite`.
public final class CodexIndex: AgentIndexer {
    public let agent = AgentKind.codex
    private let databasePath: String
    private let binaryPath: String

    public init(home: String = AgentBinaries.codexHome, binaries: AgentBinaries = AgentBinaries()) {
        self.databasePath = home + "/state_5.sqlite"
        self.binaryPath = binaries.codex
    }

    public func scan() -> [IndexedConversation] {
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
        guard let db = openReadOnly(self.databasePath) else {
            BridgeLog.index.error("codex: cannot open database")
            return []
        }
        defer { sqlite3_close(db) }

        // Parent edges are authoritative (spec: parent ids come from
        // thread_spawn_edges, not attached_thread_parent_id).
        var parents: [String: String] = [:]
        var edgeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT parent_thread_id, child_thread_id FROM thread_spawn_edges", -1, &edgeStmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(edgeStmt) }
        while sqlite3_step(edgeStmt) == SQLITE_ROW {
            let parent = String(cString: sqlite3_column_text(edgeStmt, 0))
            let child = String(cString: sqlite3_column_text(edgeStmt, 1))
            parents[child] = parent
        }

        var rows: [IndexedConversation] = []
        let columns = """
            id, rollout_path, cwd, name, title, preview, updated_at, updated_at_ms,
            archived, thread_source, first_user_message
            """
        var stmt: OpaquePointer?
        let query = "SELECT \(columns) FROM threads"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let rolloutPath = String(cString: sqlite3_column_text(stmt, 1))
            let cwd = String(cString: sqlite3_column_text(stmt, 2))
            let name = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let title = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let preview = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let updatedAtSec = sqlite3_column_int64(stmt, 6)
            let updatedAtMs = sqlite3_column_int64(stmt, 7)
            let updatedAt = updatedAtMs > 0 ? updatedAtMs : updatedAtSec * 1000
            let archived = sqlite3_column_int64(stmt, 8) == 1
            let threadSource = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? ""
            let firstUserMessage = sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? ""

            let effectiveTitle = Self.title(name: name, title: title, preview: preview, firstUserMessage: firstUserMessage, id: id)

            // Subagent / realtime_voice threads are not resumable and do not
            // create projects (their cwd may be a container path).
            let isSubagent = threadSource == "subagent"
            let isVoice = threadSource == "realtime_voice"
            let parent = isSubagent ? parents[id] : nil

            // The rollout the writer actually appends to: sqlite's
            // rollout_path may be missing while its .zst sibling exists.
            let resolvedRollout = Self.resolveRollout(rolloutPath)

            rows.append(IndexedConversation(
                agent: .codex,
                nativeId: id,
                cwd: cwd,
                title: effectiveTitle,
                updatedAt: updatedAt,
                archived: archived,
                resumable: !isSubagent && !isVoice && FileManager.default.fileExists(atPath: binaryPath),
                resumableError: (isSubagent || isVoice) ? "not_resumable" : nil,
                parentNativeId: parent,
                sourcePath: resolvedRollout,
                emptyHistory: false
            ))
        }
        BridgeLog.index.info("codex: indexed \(rows.count) threads")
        return rows
    }

    static func title(name: String, title: String, preview: String, firstUserMessage: String, id: String) -> String {
        // name → title → truncated preview/first message → id prefix.
        if !name.isEmpty { return name }
        if !title.isEmpty { return title }
        let candidate = preview.isEmpty ? firstUserMessage : preview
        if !candidate.isEmpty {
            let flattened = candidate.replacingOccurrences(of: "\n", with: " ")
            let prefix = String(flattened.prefix(80)).trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty { return prefix }
        }
        return String(id.prefix(8))
    }

    /// `rollout_path` may point at a missing `*.jsonl`; the archived store
    /// keeps its `*.jsonl.zst` sibling. Watch whichever exists.
    static func resolveRollout(_ rolloutPath: String) -> String {
        if FileManager.default.fileExists(atPath: rolloutPath) {
            return rolloutPath
        }
        let zst = rolloutPath + ".zst"
        if FileManager.default.fileExists(atPath: zst) {
            return zst
        }
        return rolloutPath
    }

    func openReadOnly(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        let uri = "file:\(path)?mode=ro&immutable=1"
        if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
            return db
        }
        sqlite3_close(db)
        // Fall back to a scratch copy when the store refuses concurrent readers.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-codex-\(UUID().uuidString).sqlite")
        do {
            try FileManager.default.copyItem(atPath: path, toPath: scratch.path)
            var copyDb: OpaquePointer?
            if sqlite3_open_v2(scratch.path, &copyDb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                return copyDb
            }
            sqlite3_close(copyDb)
        } catch {
            BridgeLog.index.error("codex: scratch copy failed \(error.localizedDescription)")
        }
        return nil
    }
}
