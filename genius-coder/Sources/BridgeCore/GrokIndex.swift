import Foundation
import PhoneProtocol

/// Scans `$GROK_HOME/sessions/<encoded-cwd>/<session-id>/summary.json`.
/// The list metadata is `summary.json`; the renderable log is
/// `updates.jsonl`. `prompt_history.jsonl` is neither (spec decision 2).
public final class GrokIndex: AgentIndexer {
    public let agent = AgentKind.grok
    private let sessionsRoot: String
    private let binaryPath: String

    public init(home: String = AgentBinaries.grokHome, binaries: AgentBinaries = AgentBinaries()) {
        self.sessionsRoot = home + "/sessions"
        self.binaryPath = binaries.grok
    }

    struct SummaryFile: Decodable {
        struct Info: Decodable {
            var id: String?
            var cwd: String?
        }
        var info: Info?
        var generated_title: String?
        var session_summary: String?
        var updated_at: String?
        var last_active_at: String?
        var git_root_dir: String?
        var session_kind: String?
        var parent_session_id: String?
    }

    public func scan() -> [IndexedConversation] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsRoot) else { return [] }
        guard let encodedDirs = try? fm.contentsOfDirectory(atPath: sessionsRoot) else { return [] }

        let binaryExists = fm.fileExists(atPath: binaryPath)
        var rows: [IndexedConversation] = []
        let decoder = JSONDecoder()

        for encoded in encodedDirs {
            let sessionRoot = (sessionsRoot as NSString).appendingPathComponent(encoded)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sessionRoot, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let sessionDirs = try? fm.contentsOfDirectory(atPath: sessionRoot) else { continue }
            for session in sessionDirs {
                let dir = (sessionRoot as NSString).appendingPathComponent(session)
                guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
                let summaryPath = (dir as NSString).appendingPathComponent("summary.json")
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: summaryPath)),
                      let summary = try? decoder.decode(SummaryFile.self, from: data),
                      let id = summary.info?.id, let cwd = summary.info?.cwd else { continue }

                let kind = summary.session_kind ?? ""
                let isSubagent = kind == "subagent" || kind == "subagent_resume"
                let updatesPath = (dir as NSString).appendingPathComponent("updates.jsonl")
                let hasUpdates = fm.fileExists(atPath: updatesPath)

                let updatedAt = Self.timestampMs(
                    updated_at: summary.updated_at, last_active_at: summary.last_active_at
                ) ?? Self.mtime(updatesPath)

                rows.append(IndexedConversation(
                    agent: .grok,
                    nativeId: id,
                    cwd: cwd,
                    title: Self.title(generated: summary.generated_title, summaryText: summary.session_summary, id: id),
                    updatedAt: updatedAt,
                    archived: false,
                    resumable: binaryExists,
                    resumableError: nil,
                    parentNativeId: isSubagent ? summary.parent_session_id : nil,
                    sourcePath: dir,
                    emptyHistory: !hasUpdates
                ))
            }
        }
        BridgeLog.index.info("grok: indexed \(rows.count) sessions")
        return rows
    }

    static func title(generated: String?, summaryText: String?, id: String) -> String {
        if let generated, !generated.isEmpty { return generated }
        if let text = summaryText, !text.isEmpty { return text }
        return String(id.prefix(8))
    }

    /// ISO-8601 with fractional seconds → epoch ms.
    static func timestampMs(updated_at: String?, last_active_at: String?) -> Int64? {
        for candidate in [updated_at, last_active_at] {
            guard let s = candidate, !s.isEmpty else { continue }
            // 2026-10-15T08:04:02.840615Z
            let normalized = s.replacingOccurrences(of: "Z", with: "+0000")
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            if let date = formatter.date(from: normalized) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            if let date = formatter.date(from: normalized) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }

    static func mtime(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
    }
}
