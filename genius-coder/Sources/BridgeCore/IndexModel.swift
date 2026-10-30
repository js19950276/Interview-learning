import Foundation
import PhoneProtocol

/// Provider-neutral row the indexers emit. The store aggregates these into
/// projects keyed by canonical path.
public struct IndexedConversation {
    public var agent: AgentKind
    public var nativeId: String
    public var conversationId: String
    /// cwd as recorded by the agent store (raw).
    public var cwd: String
    public var title: String
    /// Epoch ms.
    public var updatedAt: Int64
    public var archived: Bool
    public var resumable: Bool
    public var resumableError: String?
    /// Native parent id when this row is a subagent.
    public var parentNativeId: String?
    /// Agent-specific source pointer (Codex rollout path, Grok session dir,
    /// dsh log path, Claude jsonl path).
    public var sourcePath: String?
    /// True when the authoritative log is absent (Grok without updates.jsonl).
    public var emptyHistory: Bool

    public init(
        agent: AgentKind,
        nativeId: String,
        cwd: String,
        title: String,
        updatedAt: Int64,
        archived: Bool = false,
        resumable: Bool = true,
        resumableError: String? = nil,
        parentNativeId: String? = nil,
        sourcePath: String? = nil,
        emptyHistory: Bool = false
    ) {
        self.agent = agent
        self.nativeId = nativeId
        self.conversationId = "\(agent.rawValue):\(nativeId)"
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
        self.archived = archived
        self.resumable = resumable
        self.resumableError = resumableError
        self.parentNativeId = parentNativeId
        self.sourcePath = sourcePath
        self.emptyHistory = emptyHistory
    }
}

public struct IndexedProject {
    public var projectId: String
    public var canonicalPath: String
    public var displayName: String
    public var missing: Bool

    public init(canonicalPath: String, missing: Bool) {
        self.canonicalPath = canonicalPath
        self.projectId = ProjectID(canonicalPath: canonicalPath)?.rawValue ?? "proj_invalid"
        self.displayName = URL(fileURLWithPath: canonicalPath).lastPathComponent
        self.missing = missing
    }
}

/// Protocol each agent store indexer implements. All read-only metadata.
public protocol AgentIndexer {
    var agent: AgentKind { get }
    /// Scan the store; never throws — unparsable rows degrade to
    /// `resumable = false` with an error code, the index survives.
    func scan() -> [IndexedConversation]
}

/// Absolute binary locations probed by the bridge. GUI processes do not
/// inherit the login shell PATH (spec: Background → GUI 进程拿不到 PATH).
public struct AgentBinaries {
    public var codexOverride: String?
    public var grokOverride: String?
    public var claudeOverride: String?
    public var nodeOverride: String?
    public var dshOverride: String?

    public static let defaultCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
    public static let defaultGrok = NSString(string: "~/.grok/bin/grok").expandingTildeInPath
    public static let defaultClaude = NSString(string: "~/.local/share/node-v24.18.1/bin/claude").expandingTildeInPath
    public static let defaultNode = NSString(string: "~/.local/share/node-v24.18.1/bin/node").expandingTildeInPath
    public static let defaultDsh = "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"

    public init(
        codexOverride: String? = nil,
        grokOverride: String? = nil,
        claudeOverride: String? = nil,
        nodeOverride: String? = nil,
        dshOverride: String? = nil
    ) {
        self.codexOverride = codexOverride
        self.grokOverride = grokOverride
        self.claudeOverride = claudeOverride
        self.nodeOverride = nodeOverride
        self.dshOverride = dshOverride
    }

    public var codex: String { codexOverride ?? Self.defaultCodex }
    public var grok: String { grokOverride ?? Self.defaultGrok }
    public var claude: String { claudeOverride ?? Self.defaultClaude }
    public var node: String { nodeOverride ?? Self.defaultNode }
    public var dsh: String { dshOverride ?? Self.defaultDsh }

    public func exists(_ agent: AgentKind) -> Bool {
        let path: String
        switch agent {
        case .codex: path = codex
        case .grok: path = grok
        case .claude: path = FileManager.default.fileExists(atPath: claude) ? claude : claude
        case .deepseek: path = dsh
        }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Standard store roots for this machine.
    public static var codexHome: String { NSString(string: "~/.codex").expandingTildeInPath }
    public static var grokHome: String {
        ProcessInfo.processInfo.environment["GROK_HOME"]
            ?? NSString(string: "~/.grok").expandingTildeInPath
    }
    public static var claudeProjects: String {
        NSString(string: "~/.claude/projects").expandingTildeInPath
    }
    public static var dshHome: String {
        ProcessInfo.processInfo.environment["DSH_HOME"]
            ?? NSString(string: "~/.dsh").expandingTildeInPath
    }
}
