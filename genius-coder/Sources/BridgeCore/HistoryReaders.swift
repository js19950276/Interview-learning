import Foundation
import PhoneProtocol

/// Grok history: renders `updates.jsonl` only. `chat_history.jsonl` is the
/// model's raw input and `prompt_history.jsonl` is neither index nor render
/// input (spec decision 2).
public enum GrokHistory {
    /// Parse an updates.jsonl body into normalized events (oldest first).
    public static func parse(data: Data) -> [ConversationEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var events: [ConversationEvent] = []
        var seq: Int64 = 1
        for piece in text.split(separator: "\n") {
            let line = Data(piece.utf8)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let method = obj["method"] as? String, method == "session/update",
                  let params = obj["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  let kind = update["sessionUpdate"] as? String else { continue }
            let content = update["content"] as? [String: Any]
            let timestampNumber = obj["timestamp"] as? NSNumber
            let at: Int64? = timestampNumber.map { $0.int64Value * 1000 }
            switch kind {
            case "user_message_chunk":
                if let text = content?["text"] as? String {
                    events.append(ConversationEvent(seq: seq, kind: .userMessage, text: text, at: at))
                    seq += 1
                }
            case "agent_message_chunk":
                if let text = content?["text"] as? String {
                    events.append(ConversationEvent(seq: seq, kind: .assistantTextDelta, text: text, at: at))
                    seq += 1
                }
            case "agent_thought_chunk":
                if let text = content?["text"] as? String {
                    events.append(ConversationEvent(seq: seq, kind: .thinkingDelta, text: text, at: at))
                    seq += 1
                }
            case "tool_call", "tool_call_update":
                // content: { toolCallId, title, kind?, rawOutput?, status? }
                let callId = content?["toolCallId"] as? String ?? content?["callId"] as? String
                let title = content?["title"] as? String
                let raw = content?["rawOutput"] as? String
                let status = content?["status"] as? String
                var toolStatus: ToolCallStatus? = nil
                switch status {
                case "pending": toolStatus = .pending
                case "in_progress": toolStatus = .inProgress
                case "completed": toolStatus = .completed
                case "failed": toolStatus = .failed
                default: break
                }
                if let raw, kind == "tool_call_update" {
                    let preview = String(raw.prefix(EventLimits.toolOutputPreviewBytes / 4))
                    events.append(ConversationEvent(seq: seq, kind: .toolResult, toolName: title, toolPreview: preview, toolStatus: toolStatus ?? .completed, callId: callId, at: at))
                    seq += 1
                } else {
                    events.append(ConversationEvent(seq: seq, kind: .toolCall, toolName: title, toolPreview: nil, toolStatus: toolStatus ?? .inProgress, callId: callId, at: at))
                    seq += 1
                }
            case "plan":
                if let plan = content?["plan"] as? String {
                    events.append(ConversationEvent(seq: seq, kind: .status, detail: plan, at: at))
                    seq += 1
                }
            case "turn_completed":
                let usage = parseUsage(obj["usage"] as? [String: Any] ?? update["usage"] as? [String: Any])
                events.append(ConversationEvent(seq: seq, kind: .status, detail: "turn_completed", usage: usage, at: at))
                seq += 1
            default:
                // Unknown sessionUpdate: debug log, dropped (spec: Grok).
                continue
            }
        }
        return events
    }

    static func parseUsage(_ dict: [String: Any]?) -> UsageDelta? {
        guard let dict else { return nil }
        func pick(_ keys: [String]) -> Int64? {
            for key in keys {
                if let n = dict[key] as? NSNumber { return n.int64Value }
                if let s = dict[key] as? String, let v = Int64(s) { return v }
            }
            return nil
        }
        let usage = UsageDelta(
            inputTokens: pick(["inputTokens", "input_tokens", "cachedInputTokens"]),
            outputTokens: pick(["outputTokens", "output_tokens"]),
            cacheReadTokens: pick(["cacheReadTokens", "cachedInputTokens"]),
            cacheWriteTokens: pick(["cacheWriteTokens"])
        )
        if usage.inputTokens == nil && usage.outputTokens == nil { return nil }
        return usage
    }

    public static func load(sessionDirectory: String) -> [ConversationEvent] {
        let path = (sessionDirectory as NSString).appendingPathComponent("updates.jsonl")
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return parse(data: data)
    }
}

/// dsh history: disk only — `session/resume` never replays old updates
/// (spec: DeepSeek adapter). Reads `session.v4.jsonl.zstd` through the
/// linked zstd library.
public enum DshHistory {
    public struct ParseResult {
        public var events: [ConversationEvent]
        public var header: Header?
        public var error: PhoneErrorCode?
    }

    public struct Header {
        public var version: Int
        public var cwd: String
        public var createdAt: Int64
        public var id: String
    }

    public static func load(logPath: String) -> ParseResult {
        guard let data = FileManager.default.contents(atPath: logPath) else {
            return ParseResult(events: [], header: nil, error: .sessionUnreadable)
        }
        let raw: Data
        do {
            raw = try DshZstd.decompress(data)
        } catch {
            BridgeLog.dsh.error("zstd failed on \((logPath as NSString).lastPathComponent): \(error.localizedDescription)")
            return ParseResult(events: [], header: nil, error: .sessionUnreadable)
        }
        guard let text = String(data: raw, encoding: .utf8) else {
            return ParseResult(events: [], header: nil, error: .sessionUnreadable)
        }
        var events: [ConversationEvent] = []
        var header: Header?
        var seq: Int64 = 1
        for piece in text.split(separator: "\n") {
            let line = Data(piece.utf8)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            let time = (obj["time"] as? NSNumber)?.int64Value ?? 0
            if type == "session" {
                let version = obj["version"] as? Int ?? -1
                header = Header(
                    version: version,
                    cwd: obj["cwd"] as? String ?? "",
                    createdAt: (obj["createdAt"] as? NSNumber)?.int64Value ?? 0,
                    id: obj["id"] as? String ?? ""
                )
                if !DshIndex.supportedVersions.contains(version) {
                    return ParseResult(events: [], header: header, error: .unsupportedSessionVersion)
                }
                continue
            }
            let dataObj = obj["data"]
            switch type {
            case "command/run":
                if let dict = dataObj as? [String: Any] {
                    let name = dict["name"] as? String ?? "command"
                    let args = dict["args"]
                    let preview = args.flatMap { shortPreview($0) }
                    events.append(ConversationEvent(seq: seq, kind: .toolCall, toolName: name, toolPreview: preview, toolStatus: .inProgress, callId: dict["commandId"] as? String, at: time))
                    seq += 1
                }
            case "command/done":
                if let dict = dataObj as? [String: Any] {
                    let kindDone = dict["kind"] as? String ?? "success"
                    let preview = dict["text"] as? String
                    events.append(ConversationEvent(seq: seq, kind: .toolResult, toolName: nil, toolPreview: preview.map { String($0.prefix(2000)) }, toolStatus: kindDone == "success" ? .completed : .failed, callId: dict["commandId"] as? String, at: time))
                    seq += 1
                }
            case "agent/inbox/spliced":
                if let dict = dataObj as? [String: Any],
                   let inserted = dict["inserted"] as? [[String: Any]] {
                    for item in inserted {
                        if let content = item["content"] as? [String: Any],
                           let text = content["text"] as? String, !text.isEmpty {
                            events.append(ConversationEvent(seq: seq, kind: .userMessage, text: text, at: time))
                            seq += 1
                        }
                    }
                }
            default:
                // Permission presets, sandbox modes, seeding markers and any
                // unknown types are metadata, not transcript content.
                continue
            }
        }
        return ParseResult(events: events, header: header, error: nil)
    }

    static func shortPreview(_ value: Any) -> String? {
        if let s = value as? String { return String(s.prefix(200)) }
        if let arr = value as? [Any] {
            let joined = arr.compactMap { $0 as? String }.joined(separator: " ")
            return joined.isEmpty ? nil : String(joined.prefix(200))
        }
        return nil
    }
}

/// Cursor-based paging over a full in-memory event list. Pages are
/// newest-first windows returned oldest-event-first (spec: 列表和打开).
public struct HistoryPager {
    public let all: [ConversationEvent]

    public init(events: [ConversationEvent]) {
        self.all = events
    }

    /// Newest page (oldest-first inside the page).
    public func newestPage() -> (events: [ConversationEvent], olderCursor: String?) {
        page(endingAt: all.count)
    }

    public func page(cursor: String) -> (events: [ConversationEvent], olderCursor: String?)? {
        guard let index = Self.decode(cursor), index <= all.count else { return nil }
        return page(endingAt: index)
    }

    private func page(endingAt end: Int) -> (events: [ConversationEvent], olderCursor: String?) {
        var start = end
        var bytes = 0
        var count = 0
        while start > 0 && count < EventLimits.historyPageEventCount {
            let event = all[start - 1]
            let size = approxSize(event)
            if count > 0 && bytes + size > EventLimits.historyPageBytes { break }
            bytes += size
            count += 1
            start -= 1
        }
        let slice = Array(all[start..<end])
        let older: String? = start > 0 ? Self.encode(start) : nil
        return (slice, older)
    }

    static func encode(_ index: Int) -> String {
        Data("o:\(index)".utf8).base64EncodedString()
    }

    static func decode(_ cursor: String) -> Int? {
        guard let data = Data(base64Encoded: cursor),
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("o:"),
              let value = Int(text.dropFirst(2)) else { return nil }
        return value
    }

    private func approxSize(_ event: ConversationEvent) -> Int {
        (event.text?.utf8.count ?? 0) + (event.toolPreview?.utf8.count ?? 0) + (event.diff?.utf8.count ?? 0) + 64
    }
}
