import Foundation
import PhoneProtocol

/// Fail-closed approval tracking (spec: 批准 + 断线 15 秒宽限).
///
/// Every approval gets a bridge-generated id (`ap_N`), exactly the two
/// bridge-defined answers ("allow"/"deny", via `ApprovalOption.isValid`) and
/// single-use resolution. Disconnect grace uses the monotonic clock only —
/// no wall clock anywhere, so a wall-clock jump can never revive or extend
/// an answer window.
public final class ApprovalCenter: @unchecked Sendable {

    public struct Pending {
        public let approvalId: String
        public let conversationId: String
        public let kind: PendingKind
        public let createdAt: ContinuousClock.Instant

        public init(
            approvalId: String,
            conversationId: String,
            kind: PendingKind,
            createdAt: ContinuousClock.Instant
        ) {
            self.approvalId = approvalId
            self.conversationId = conversationId
            self.kind = kind
            self.createdAt = createdAt
        }
    }

    public enum PendingKind: Equatable {
        /// Normalized kinds (spec: 批准).
        case commandExecution
        case fileChange
        case permissionsUpgrade(profile: Data?)
        /// Vendor-legacy shapes kept for adapter fidelity.
        case legacyExecCommand
        case legacyApplyPatch
        case acp(sessionId: String, request: JSONValue)
        case claude(requestId: String)
        /// Fallback: raw server method plus payload.
        case server(method: String, payload: JSONValue?)
    }

    /// Cap on retained resolved approvals; older answered entries are pruned
    /// so a long-lived bridge cannot grow without bound.
    private static let memoryLimit = 256

    private let clock: ContinuousClock
    private let queue = DispatchQueue(label: "genius-coder.approvals")
    private var nextNumber = 0
    private var pendings: [String: Pending] = [:]
    private var answers: [String: String] = [:]
    private var order: [String] = []
    /// conversationId -> grace deadline (monotonic).
    private var graces: [String: ContinuousClock.Instant] = [:]

    public init(clock: ContinuousClock = ContinuousClock()) {
        self.clock = clock
    }

    // MARK: - Register / resolve

    /// Register a pending approval derived from a vendor server request and
    /// return its bridge id ("ap_N").
    @discardableResult
    public func register(conversationId: String, serverMethod: String, payload: JSONValue?) -> String {
        register(conversationId: conversationId, kind: Self.classify(serverMethod: serverMethod, payload: payload))
    }

    /// Register with an explicit (usually normalized) kind.
    @discardableResult
    public func register(conversationId: String, kind: PendingKind) -> String {
        queue.sync {
            nextNumber += 1
            let id = "ap_\(nextNumber)"
            pendings[id] = Pending(
                approvalId: id,
                conversationId: conversationId,
                kind: kind,
                createdAt: clock.now
            )
            order.append(id)
            pruneLocked()
            return id
        }
    }

    /// Map a vendor server method (+ payload) onto a `PendingKind`.
    /// Unknown shapes fall back to `.server`.
    public static func classify(serverMethod: String, payload: JSONValue?) -> PendingKind {
        let method = serverMethod.lowercased()
        if method.contains("acp"),
           let payload,
           let sessionId = payload["sessionId"]?.stringValue {
            return .acp(sessionId: sessionId, request: payload)
        }
        if let payload,
           let requestId = payload["requestId"]?.stringValue ?? payload["id"]?.stringValue,
           method.contains("claude") || method.contains("control") {
            return .claude(requestId: requestId)
        }
        if method.contains("exec_command") || method.contains("execcommand") {
            return .legacyExecCommand
        }
        if method.contains("apply_patch") || method.contains("applypatch") {
            return .legacyApplyPatch
        }
        return .server(method: serverMethod, payload: payload)
    }

    /// Record the phone's answer. Only "allow"/"deny" are accepted; anything
    /// else is rejected and the approval stays unanswered. Single-use: a
    /// second resolve (even with a valid option) returns false.
    @discardableResult
    public func resolve(approvalId: String, optionId: String) -> Bool {
        queue.sync {
            guard pendings[approvalId] != nil, answers[approvalId] == nil else { return false }
            guard ApprovalOption.isValid(optionId) else { return false }
            answers[approvalId] = optionId
            return true
        }
    }

    /// "allow" / "deny" once resolved, nil while unanswered or unknown.
    public func pendingAnswer(approvalId: String) -> String? {
        queue.sync { answers[approvalId] }
    }

    public func pending(approvalId: String) -> Pending? {
        queue.sync { pendings[approvalId] }
    }

    public func unanswered(conversationId: String) -> [Pending] {
        queue.sync {
            order.compactMap { id -> Pending? in
                guard let p = pendings[id], p.conversationId == conversationId, answers[id] == nil else { return nil }
                return p
            }
        }
    }

    public func hasUnanswered(conversationId: String) -> Bool {
        !unanswered(conversationId: conversationId).isEmpty
    }

    // MARK: - Disconnect grace (spec: 断线 15 秒宽限)

    /// Arm the disconnect grace for a conversation. Unanswered approvals are
    /// denied once `EventLimits.approvalGraceSeconds` of monotonic time has
    /// passed past `deadline`.
    public func startGrace(conversationId: String, deadline: ContinuousClock.Instant) {
        queue.sync {
            graces[conversationId] = deadline
        }
    }

    public func cancelGrace(conversationId: String) {
        queue.sync { _ = graces.removeValue(forKey: conversationId) }
    }

    /// Conversations whose grace deadline has passed at `now` while still
    /// holding unanswered approvals. Returned once; the grace is consumed.
    /// Conversations whose approvals were all answered during the grace are
    /// dropped (nothing to deny).
    public func expiredGraces(now: ContinuousClock.Instant) -> [String] {
        queue.sync {
            var expired: [String] = []
            for (conversationId, deadline) in graces where deadline <= now {
                graces.removeValue(forKey: conversationId)
                let hasUnanswered = pendings.values.contains {
                    $0.conversationId == conversationId && answers[$0.approvalId] == nil
                }
                if hasUnanswered {
                    expired.append(conversationId)
                }
            }
            return expired
        }
    }

    // MARK: - Internals

    /// Caller holds the queue. Keeps the newest entries; only prunes
    /// answered approvals so live pendings are never dropped.
    private func pruneLocked() {
        guard order.count > Self.memoryLimit else { return }
        var kept: [String] = []
        var toDrop = order.count - Self.memoryLimit
        for id in order {
            if toDrop > 0, answers[id] != nil {
                toDrop -= 1
                pendings.removeValue(forKey: id)
                answers.removeValue(forKey: id)
            } else {
                kept.append(id)
            }
        }
        order = kept
    }
}
