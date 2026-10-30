import SwiftUI
import PhoneProtocol

struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    let conversation: ConversationSummary

    private var session: OpenSession? {
        guard let open = model.openSession,
              open.conversationId == conversation.conversationId else {
            return nil
        }
        return open
    }

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                ProgressView("正在打开会话…")
            }
        }
        .navigationTitle(conversation.title.isEmpty ? "会话" : conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: conversation.conversationId) {
            await model.openConversation(conversation.conversationId)
        }
    }

    @ViewBuilder
    private func content(_ session: OpenSession) -> some View {
        VStack(spacing: 0) {
            if let notice = friendlyNotice(session) {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(Color(uiColor: .secondarySystemBackground))
            }
            transcript(session)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let approval = session.approval {
                    ApprovalCard(approval: approval) { optionId in
                        Task { await model.approve(optionId: optionId) }
                    }
                }
                ComposerBar()
            }
            .background(.bar)
        }
    }

    @ViewBuilder
    private func transcript(_ session: OpenSession) -> some View {
        let blocks = TranscriptBuilder.blocks(from: session.events)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if session.olderCursor != nil {
                        Button {
                            Task { await model.loadOlder() }
                        } label: {
                            Label("加载更早的消息", systemImage: "arrow.up.circle")
                                .font(.footnote)
                        }
                        .padding(.vertical, 6)
                    }
                    ForEach(blocks) { block in
                        BlockView(block: block)
                            .id(block.id)
                    }
                    if let usage = TranscriptBuilder.usageText(from: session.events) {
                        Text(usage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.events.count) { _, _ in
                if let last = blocks.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func friendlyNotice(_ session: OpenSession) -> String? {
        if session.sessionState.detail == PhoneErrorCode.emptyHistory.rawValue
            || session.openNotice == PhoneErrorCode.emptyHistory.rawValue {
            return "这个会话还没有内容。"
        }
        if session.openNotice == "offline" {
            return "离线：正在显示本地缓存，发送已停用。"
        }
        guard session.events.isEmpty else { return nil }
        if session.sessionState.phase == .unavailable {
            if let reason = session.summary?.resumableError {
                return "这个会话不可续聊：\(reason)"
            }
            return "这个会话目前不可续聊。"
        }
        return nil
    }
}

// MARK: - Transcript building

enum TranscriptBuilder {
    struct Block: Identifiable {
        let id: String
        let content: Content

        enum Content {
            case user(String)
            case assistant(String)
            case thinking(String)
            case tool(name: String, status: ToolCallStatus?, preview: String?)
            case diff(String)
            case note(String)
        }
    }

    static func blocks(from events: [ConversationEvent]) -> [Block] {
        var blocks: [Block] = []
        var toolIndexByCallId: [String: Int] = [:]
        var assistantBuffer = ""
        var assistantFirstSeq: Int64?
        var thinkingBuffer = ""
        var thinkingFirstSeq: Int64?

        func flushAssistant() {
            guard let first = assistantFirstSeq else { return }
            blocks.append(Block(id: "a-\(first)", content: .assistant(assistantBuffer)))
            assistantBuffer = ""
            assistantFirstSeq = nil
        }
        func flushThinking() {
            guard let first = thinkingFirstSeq else { return }
            blocks.append(Block(id: "t-\(first)", content: .thinking(thinkingBuffer)))
            thinkingBuffer = ""
            thinkingFirstSeq = nil
        }
        func flushAll() {
            flushAssistant()
            flushThinking()
        }

        for event in events {
            switch event.kind {
            case .userMessage:
                flushAll()
                blocks.append(Block(id: "u-\(event.seq)", content: .user(event.text ?? "")))
            case .assistantTextDelta:
                flushThinking()
                if assistantFirstSeq == nil { assistantFirstSeq = event.seq }
                assistantBuffer += event.text ?? ""
            case .thinkingDelta:
                flushAssistant()
                if thinkingFirstSeq == nil { thinkingFirstSeq = event.seq }
                thinkingBuffer += event.text ?? ""
            case .toolCall:
                flushAll()
                blocks.append(Block(
                    id: "tc-\(event.seq)",
                    content: .tool(
                        name: event.toolName ?? "tool",
                        status: event.toolStatus,
                        preview: event.toolPreview
                    )
                ))
                if let callId = event.callId {
                    toolIndexByCallId[callId] = blocks.count - 1
                }
            case .toolResult:
                flushAll()
                if let callId = event.callId,
                   let index = toolIndexByCallId[callId],
                   case .tool(let name, let oldStatus, let oldPreview) = blocks[index].content {
                    blocks[index] = Block(
                        id: blocks[index].id,
                        content: .tool(
                            name: name,
                            status: event.toolStatus ?? oldStatus,
                            preview: event.toolPreview ?? oldPreview
                        )
                    )
                } else {
                    blocks.append(Block(
                        id: "tr-\(event.seq)",
                        content: .tool(
                            name: event.toolName ?? "tool",
                            status: event.toolStatus,
                            preview: event.toolPreview
                        )
                    ))
                }
            case .diff:
                flushAll()
                blocks.append(Block(id: "d-\(event.seq)", content: .diff(event.diff ?? event.text ?? "")))
            case .approvalRequest:
                flushAll()
                let what = event.text ?? event.detail ?? ""
                blocks.append(Block(id: "ar-\(event.seq)", content: .note("请求批准\(what.isEmpty ? "" : "：\(what)")")))
            case .approvalResolved:
                flushAll()
                blocks.append(Block(id: "as-\(event.seq)", content: .note(event.text ?? event.detail ?? "批准已处理")))
            case .status:
                flushAll()
                if let text = event.text ?? event.detail, !text.isEmpty {
                    blocks.append(Block(id: "s-\(event.seq)", content: .note(text)))
                }
            case .usage, .snapshot:
                continue
            }
        }
        flushAll()
        return blocks
    }

    static func usageText(from events: [ConversationEvent]) -> String? {
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheWrite: Int64 = 0
        var seen = false
        for event in events where event.kind == .usage {
            seen = true
            input += event.usage?.inputTokens ?? 0
            output += event.usage?.outputTokens ?? 0
            cacheRead += event.usage?.cacheReadTokens ?? 0
            cacheWrite += event.usage?.cacheWriteTokens ?? 0
        }
        guard seen else { return nil }
        return "tokens · 输入 \(input) · 输出 \(output) · 缓存读 \(cacheRead) · 缓存写 \(cacheWrite)"
    }
}

// MARK: - Block views

struct BlockView: View {
    let block: TranscriptBuilder.Block

    var body: some View {
        switch block.content {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
        case .assistant(let text):
            HStack {
                Text(text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 40)
            }
        case .thinking(let text):
            ThinkingBlock(text: text)
        case .tool(let name, let status, let preview):
            ToolCard(name: name, status: status, preview: preview)
        case .diff(let text):
            DiffCard(text: text)
        case .note(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }
}

/// 思考块默认折叠，点开展开。
struct ThinkingBlock: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("思考过程", systemImage: "brain.head.profile")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ToolCard: View {
    let name: String
    let status: ToolCallStatus?
    let preview: String?

    private var statusText: String {
        switch status {
        case .pending: return "等待中"
        case .inProgress: return "执行中"
        case .completed: return "完成"
        case .failed: return "失败"
        case .denied: return "已拒绝"
        case nil: return ""
        }
    }

    private var statusSymbol: String {
        switch status {
        case .pending: return "clock"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        case .denied: return "hand.raised"
        case nil: return "wrench.and.screwdriver"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(.tint)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let preview, !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(6)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 工具输出超过 32 KiB 只给预览。
                if preview.utf8.count >= 1024 {
                    Text("工具输出超长，仅显示预览（上限 \(EventLimits.toolOutputPreviewBytes / 1024) KiB）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct DiffCard: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Approval card

struct ApprovalCard: View {
    let approval: PendingApproval
    let onChoose: (String) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Label("需要你的批准", systemImage: "shield.lefthalf.filled")
                .font(.headline)
            HStack(spacing: 12) {
                ForEach(approval.options, id: \.id) { option in
                    Button {
                        onChoose(option.id)
                    } label: {
                        Text(Self.label(for: option))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(option.id == "deny" ? .red : .green)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private static func label(for option: ApprovalOption) -> String {
        switch option.id {
        case ApprovalOption.allow.id: return "允许"
        case ApprovalOption.deny.id: return "拒绝"
        default: return option.title
        }
    }
}

// MARK: - Composer

struct ComposerBar: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""

    private var phase: SessionPhase? {
        model.openSession?.sessionState.phase
    }

    var body: some View {
        VStack(spacing: 6) {
            if let reason = disabledReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("输入消息…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .disabled(!model.composerEnabled)
                if phase == .streaming {
                    Button {
                        Task { await model.cancel() }
                    } label: {
                        Label("取消", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else {
                    Button {
                        let text = draft
                        draft = ""
                        Task { await model.send(text: text) }
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !model.composerEnabled
                            || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Composer 停用原因：streaming / needs_approval / read_only / unavailable / failed / 断开。
    private var disabledReason: String? {
        guard let session = model.openSession else { return nil }
        if session.approval != nil {
            return "等待批准"
        }
        switch session.sessionState.phase {
        case .idle:
            if session.sessionState.connection != .connected || !model.isConnected {
                return "已断开连接，无法发送"
            }
            return nil
        case .streaming:
            return "正在回复…"
        case .needsApproval:
            return "等待批准"
        case .readOnly:
            return "桌面端正在使用这个会话"
        case .unavailable:
            return "这个会话不可续聊"
        case .failed:
            return "会话出错，重新打开试试"
        }
    }
}
