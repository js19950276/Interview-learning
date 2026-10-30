import Foundation

// MARK: - Normalized conversation events (spec: 归一化事件)

public enum ConversationEventKind: String, Codable, CaseIterable, Sendable {
    case userMessage = "user_message"
    case assistantTextDelta = "assistant_text_delta"
    case thinkingDelta = "thinking_delta"
    case toolCall = "tool_call"
    case toolResult = "tool_result"
    case diff
    case approvalRequest = "approval_request"
    case approvalResolved = "approval_resolved"
    case status
    case usage
    case snapshot
}

public enum ToolCallStatus: String, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
    case denied
}

/// Preview truncation limits from the spec.
public enum EventLimits {
    public static let toolOutputPreviewBytes = 32 * 1024
    public static let diffBytes = 64 * 1024
    public static let maxTextBytes = 64 * 1024
    public static let historyPageEventCount = 100
    public static let historyPageBytes = 256 * 1024
    public static let catchUpRingEventCount = 2000
    public static let catchUpRingBytes = 8 * 1024 * 1024
    public static let approvalGraceSeconds: Double = 15
    public static let nonceTTLSeconds: Double = 60
    public static let pairingTokenTTLSeconds: Double = 5 * 60
    public static let clientMessageIdMemory = 100
    public static let clientMessageIdTTLSeconds: Double = 24 * 60 * 60
    public static let maxLiveSessionsPerAgent = 4
    public static let grokIdleExitSeconds: Double = 10 * 60
}

public struct UsageDelta: Codable, Equatable, Sendable {
    /// Missing fields are omitted on the wire; never zero-filled.
    public var inputTokens: Int64?
    public var outputTokens: Int64?
    public var cacheReadTokens: Int64?
    public var cacheWriteTokens: Int64?

    public init(
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        cacheReadTokens: Int64? = nil,
        cacheWriteTokens: Int64? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let v = inputTokens { try c.encode(v, forKey: .inputTokens) }
        if let v = outputTokens { try c.encode(v, forKey: .outputTokens) }
        if let v = cacheReadTokens { try c.encode(v, forKey: .cacheReadTokens) }
        if let v = cacheWriteTokens { try c.encode(v, forKey: .cacheWriteTokens) }
    }
}

/// One normalized event. `seq` is monotonically increasing per conversation.
public struct ConversationEvent: Codable, Equatable, Sendable {
    public var seq: Int64
    public var kind: ConversationEventKind
    public var text: String?
    /// For tool events: name, arguments preview, status.
    public var toolName: String?
    public var toolPreview: String?
    public var toolStatus: ToolCallStatus?
    public var callId: String?
    public var diff: String?
    public var approvalId: String?
    public var options: [ApprovalOption]?
    public var detail: String?
    public var clientMessageId: String?
    public var usage: UsageDelta?
    /// Wall-clock ms when the bridge normalized the event (advisory).
    public var at: Int64?

    public init(
        seq: Int64,
        kind: ConversationEventKind,
        text: String? = nil,
        toolName: String? = nil,
        toolPreview: String? = nil,
        toolStatus: ToolCallStatus? = nil,
        callId: String? = nil,
        diff: String? = nil,
        approvalId: String? = nil,
        options: [ApprovalOption]? = nil,
        detail: String? = nil,
        clientMessageId: String? = nil,
        usage: UsageDelta? = nil,
        at: Int64? = nil
    ) {
        self.seq = seq
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.toolPreview = toolPreview
        self.toolStatus = toolStatus
        self.callId = callId
        self.diff = diff
        self.approvalId = approvalId
        self.options = options
        self.detail = detail
        self.clientMessageId = clientMessageId
        self.usage = usage
        self.at = at
    }
}

/// Approval cards always expose exactly these two bridge-defined option ids
/// (spec: 发送、流、批准). Vendor "always allow" options are dropped by the adapter.
public struct ApprovalOption: Codable, Equatable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    public static let allow = ApprovalOption(id: "allow", title: "Allow")
    public static let deny = ApprovalOption(id: "deny", title: "Deny")
    public static let phoneOptions: [ApprovalOption] = [.allow, .deny]

    /// The only ids the phone is ever allowed to send back.
    public static func isValid(_ id: String) -> Bool { id == "allow" || id == "deny" }
}

// MARK: - API body models

public struct ProjectSummary: Codable, Equatable, Sendable {
    public var projectId: String
    public var canonicalPath: String
    /// Last path component; caller disambiguates duplicates.
    public var displayName: String
    public var missing: Bool
    public var counts: [String: Int]

    public init(projectId: String, canonicalPath: String, displayName: String, missing: Bool, counts: [String: Int]) {
        self.projectId = projectId
        self.canonicalPath = canonicalPath
        self.displayName = displayName
        self.missing = missing
        self.counts = counts
    }
}

public struct ConversationSummary: Codable, Equatable, Sendable {
    public var conversationId: String
    public var agent: AgentKind
    public var projectId: String
    public var title: String
    /// Epoch ms.
    public var updatedAt: Int64
    public var archived: Bool
    public var resumable: Bool
    public var resumableError: String?
    public var parentConversationId: String?
    public var detail: String?

    public init(
        conversationId: String,
        agent: AgentKind,
        projectId: String,
        title: String,
        updatedAt: Int64,
        archived: Bool = false,
        resumable: Bool = true,
        resumableError: String? = nil,
        parentConversationId: String? = nil,
        detail: String? = nil
    ) {
        self.conversationId = conversationId
        self.agent = agent
        self.projectId = projectId
        self.title = title
        self.updatedAt = updatedAt
        self.archived = archived
        self.resumable = resumable
        self.resumableError = resumableError
        self.parentConversationId = parentConversationId
        self.detail = detail
    }
}

public struct ProjectsListRequest: Codable, Sendable {
    public var agent: AgentFilter?
    public init(agent: AgentFilter? = nil) { self.agent = agent }
}

public struct ProjectsListResponse: Codable, Sendable {
    public var projects: [ProjectSummary]
    public var indexedAt: Int64
    public init(projects: [ProjectSummary], indexedAt: Int64) {
        self.projects = projects
        self.indexedAt = indexedAt
    }
}

public struct ConversationsListRequest: Codable, Sendable {
    public var projectId: String
    public var agent: AgentFilter?
    public var limit: Int?
    public init(projectId: String, agent: AgentFilter? = nil, limit: Int? = nil) {
        self.projectId = projectId
        self.agent = agent
        self.limit = limit
    }
}

public struct ConversationsListResponse: Codable, Sendable {
    public var conversations: [ConversationSummary]
    public init(conversations: [ConversationSummary]) { self.conversations = conversations }
}

public struct ConversationOpenRequest: Codable, Sendable {
    public var conversationId: String
    public init(conversationId: String) { self.conversationId = conversationId }
}

public struct ConversationOpenResponse: Codable, Sendable {
    public var conversation: ConversationSummary
    public var state: SessionState
    /// Newest page, oldest event first, newest last (spec).
    public var events: [ConversationEvent]
    public var nextSeq: Int64
    public var olderCursor: String?
    public init(
        conversation: ConversationSummary,
        state: SessionState,
        events: [ConversationEvent],
        nextSeq: Int64,
        olderCursor: String?
    ) {
        self.conversation = conversation
        self.state = state
        self.events = events
        self.nextSeq = nextSeq
        self.olderCursor = olderCursor
    }
}

public struct ConversationHistoryRequest: Codable, Sendable {
    public var conversationId: String
    public var cursor: String?
    public init(conversationId: String, cursor: String? = nil) {
        self.conversationId = conversationId
        self.cursor = cursor
    }
}

public struct ConversationHistoryResponse: Codable, Sendable {
    /// Older page, still oldest-first (spec).
    public var events: [ConversationEvent]
    public var olderCursor: String?
    public init(events: [ConversationEvent], olderCursor: String?) {
        self.events = events
        self.olderCursor = olderCursor
    }
}

public struct ConversationSendRequest: Codable, Sendable {
    public var conversationId: String
    public var clientMessageId: String
    public var text: String
    public init(conversationId: String, clientMessageId: String, text: String) {
        self.conversationId = conversationId
        self.clientMessageId = clientMessageId
        self.text = text
    }
}

public struct ConversationCancelRequest: Codable, Sendable {
    public var conversationId: String
    public init(conversationId: String) { self.conversationId = conversationId }
}

public struct ConversationApprovalRequest: Codable, Sendable {
    public var conversationId: String
    public var approvalId: String
    public var optionId: String
    public init(conversationId: String, approvalId: String, optionId: String) {
        self.conversationId = conversationId
        self.approvalId = approvalId
        self.optionId = optionId
    }
}

public struct PingRequest: Codable, Sendable {
    public init() {}
}

public struct PingResponse: Codable, Sendable {
    public var bridgeId: String
    public var serverTime: Int64
    public init(bridgeId: String, serverTime: Int64) {
        self.bridgeId = bridgeId
        self.serverTime = serverTime
    }
}

/// Event body pushed as `conversation.event`.
public struct ConversationEventBody: Codable, Sendable {
    public var conversationId: String
    public var event: ConversationEvent
    public init(conversationId: String, event: ConversationEvent) {
        self.conversationId = conversationId
        self.event = event
    }
}

/// Event body pushed as `conversation.state`.
public struct ConversationStateBody: Codable, Sendable {
    public var conversationId: String
    public var state: SessionState
    public init(conversationId: String, state: SessionState) {
        self.conversationId = conversationId
        self.state = state
    }
}

/// Event body pushed as `conversation.snapshot` (Grok load replay newer than
/// disk, or catch-up ring overflow).
public struct ConversationSnapshotBody: Codable, Sendable {
    public var conversationId: String
    public var events: [ConversationEvent]
    public var nextSeq: Int64
    public init(conversationId: String, events: [ConversationEvent], nextSeq: Int64) {
        self.conversationId = conversationId
        self.events = events
        self.nextSeq = nextSeq
    }
}

// MARK: - Handshake bodies (spec: 握手)

public struct AuthHelloRequest: Codable, Sendable {
    public var protocolVersion: Int
    public var deviceId: String
    public var role: String
    public init(protocolVersion: Int = 1, deviceId: String, role: String = "phone") {
        self.protocolVersion = protocolVersion
        self.deviceId = deviceId
        self.role = role
    }

    public enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case deviceId
        case role
    }
}

public struct AuthHelloResponse: Codable, Sendable {
    public var nonce: String
    public var bridgeId: String
    public init(nonce: String, bridgeId: String) {
        self.nonce = nonce
        self.bridgeId = bridgeId
    }
}

public struct AuthFinishRequest: Codable, Sendable {
    public var deviceId: String
    public var signature: String
    public init(deviceId: String, signature: String) {
        self.deviceId = deviceId
        self.signature = signature
    }
}

public struct AuthEnrollRequest: Codable, Sendable {
    public var token: String
    public var deviceId: String
    public var publicKey: String
    public var name: String
    public init(token: String, deviceId: String, publicKey: String, name: String) {
        self.token = token
        self.deviceId = deviceId
        self.publicKey = publicKey
        self.name = name
    }
}

public struct AuthEnrollResponse: Codable, Sendable {
    public var bridgeId: String
    public var nonce: String
    public init(bridgeId: String, nonce: String) {
        self.bridgeId = bridgeId
        self.nonce = nonce
    }
}

public struct AuthFinishResponse: Codable, Sendable {
    public var bridgeId: String
    public init(bridgeId: String) { self.bridgeId = bridgeId }
}
