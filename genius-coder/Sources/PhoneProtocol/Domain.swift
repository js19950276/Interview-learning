import Foundation

// MARK: - Agents

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case grok
    case deepseek

    public var sendSwitchKey: String { "send.\(rawValue)" }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .deepseek: return "DeepSeek"
        }
    }
}

public enum AgentFilter: String, Codable, CaseIterable, Sendable {
    case all
    case codex
    case claude
    case grok
    case deepseek

    public var agent: AgentKind? {
        switch self {
        case .all: return nil
        case .codex: return .codex
        case .claude: return .claude
        case .grok: return .grok
        case .deepseek: return .deepseek
        }
    }
}

// MARK: - Session state machine (spec: 会话状态机)

public enum SessionPhase: String, Codable, Sendable {
    case idle
    case streaming
    case needsApproval = "needs_approval"
    case readOnly = "read_only"
    case unavailable
    case failed
}

public enum SessionConnection: String, Codable, Sendable {
    case connected
    case disconnected
}

public enum SessionWriter: String, Codable, Sendable {
    case none
    case bridge
    case desktop
    case unknown
}

public struct SessionState: Codable, Equatable, Sendable {
    public var phase: SessionPhase
    public var connection: SessionConnection
    public var writer: SessionWriter
    /// Free-form detail, e.g. `empty_history`.
    public var detail: String?

    public init(
        phase: SessionPhase,
        connection: SessionConnection,
        writer: SessionWriter,
        detail: String? = nil
    ) {
        self.phase = phase
        self.connection = connection
        self.writer = writer
        self.detail = detail
    }

    public static let initialIdle = SessionState(
        phase: .idle, connection: .connected, writer: .none
    )
}

// MARK: - Error codes (spec: 错误码 table)

public enum PhoneErrorCode: String, Codable, CaseIterable, Error, Sendable {
    case unauthenticated
    case pairingRejected = "pairing_rejected"
    case unsupportedProtocol = "unsupported_protocol"
    case cliMissing = "cli_missing"
    case authExpired = "auth_expired"
    case sessionUnreadable = "session_unreadable"
    case unsupportedSessionVersion = "unsupported_session_version"
    case unsupportedMethod = "unsupported_method"
    case claudeHistoryNeedsFixture = "claude_history_needs_fixture"
    case emptyHistory = "empty_history"
    case notResumable = "not_resumable"
    case sendDisabled = "send_disabled"
    case writerLocked = "writer_locked"
    case goalRearmedBlocked = "goal_rearmed_blocked"
    case approvalDeniedDisconnected = "approval_denied_disconnected"
    case unsupportedServerRequest = "unsupported_server_request"
    case tooManyLiveSessions = "too_many_live_sessions"
    case adapterFailed = "adapter_failed"
    case notFound = "not_found"
    case malformedRequest = "malformed_request"
    case internalError = "internal_error"
}

// MARK: - Methods

public enum PhoneMethod: String, Codable, CaseIterable, Sendable {
    case authHello = "auth.hello"
    case authEnroll = "auth.enroll"
    case authFinish = "auth.finish"
    case ping
    case projectsList = "projects.list"
    case conversationsList = "conversations.list"
    case conversationOpen = "conversation.open"
    case conversationHistory = "conversation.history"
    case conversationSend = "conversation.send"
    case conversationCancel = "conversation.cancel"
    case conversationApproval = "conversation.approval"
    case conversationSnapshot = "conversation.snapshot"

    /// Event method used for all normalized conversation events.
    public static let conversationEventMethod = "conversation.event"
    /// Event method used when the bridge pushes state transitions.
    public static let conversationStateMethod = "conversation.state"
}

// MARK: - Identifiers

/// `proj_` + first 16 hex chars of SHA-256 over the canonical path (spec: Indexer).
public struct ProjectID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init?(canonicalPath: String) {
        var digest = SHA256Helper.hex(Data(canonicalPath.utf8))
        digest = String(digest.prefix(16))
        self.rawValue = "proj_\(digest)"
    }
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum ConversationID: Hashable, Codable, Sendable, RawRepresentable {
    case codex(String)
    case grok(String)
    case claude(String)
    case deepseek(String)

    public init?(rawValue: String) {
        guard let colon = rawValue.firstIndex(of: ":") else { return nil }
        let agent = String(rawValue[rawValue.startIndex..<colon])
        let id = String(rawValue[rawValue.index(after: colon)...])
        guard !id.isEmpty else { return nil }
        switch agent {
        case "codex": self = .codex(id)
        case "grok": self = .grok(id)
        case "claude": self = .claude(id)
        case "deepseek": self = .deepseek(id)
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .codex(let id): return "codex:\(id)"
        case .grok(let id): return "grok:\(id)"
        case .claude(let id): return "claude:\(id)"
        case .deepseek(let id): return "deepseek:\(id)"
        }
    }

    public var agent: AgentKind {
        switch self {
        case .codex: return .codex
        case .grok: return .grok
        case .claude: return .claude
        case .deepseek: return .deepseek
        }
    }

    public var nativeID: String {
        switch self {
        case .codex(let id), .grok(let id), .claude(let id), .deepseek(let id):
            return id
        }
    }
}

// MARK: - Bridge identity

public struct BridgeAdvertisement: Codable, Equatable, Sendable {
    public var bridgeId: String
    /// SHA-256 of the pinned leaf certificate, hex.
    public var certFingerprint: String

    public init(bridgeId: String, certFingerprint: String) {
        self.bridgeId = bridgeId
        self.certFingerprint = certFingerprint
    }
}

/// Contents of the one-time pairing QR code (spec: 网络 → 配对).
/// `v`, `bridgeId`, `fp`, `hosts[]`, `port`, `token`, optional human `exp`.
public struct PairingQRPayload: Codable, Equatable, Sendable {
    public struct Host: Codable, Equatable, Sendable {
        public var address: String
        /// "lan" or "tailscale"
        public var kind: String
        public init(address: String, kind: String) {
            self.address = address
            self.kind = kind
        }
    }

    public var v: Int
    public var bridgeId: String
    public var fp: String
    public var hosts: [Host]
    public var port: UInt16
    public var token: String
    public var exp: Double?

    public init(v: Int = 1, bridgeId: String, fp: String, hosts: [Host], port: UInt16, token: String, exp: Double? = nil) {
        self.v = v
        self.bridgeId = bridgeId
        self.fp = fp
        self.hosts = hosts
        self.port = port
        self.token = token
        self.exp = exp
    }

    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
