import SwiftUI
import PhoneProtocol

struct ConversationListView: View {
    @EnvironmentObject private var model: AppModel
    let project: ProjectSummary

    var body: some View {
        List {
            if model.topLevelConversations.isEmpty {
                Text(
                    model.conversations.isEmpty
                        ? "还没有会话"
                        : "没有符合筛选条件的会话"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
            }
            // 子 agent 不占顶层行，收在父会话下面；v1 只显示、不能单独续聊。
            ForEach(model.topLevelConversations, id: \.conversationId) { conversation in
                Section {
                    NavigationLink {
                        ConversationView(conversation: conversation)
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    ForEach(
                        model.childConversations(of: conversation.conversationId),
                        id: \.conversationId
                    ) { child in
                        SubagentRow(conversation: child)
                    }
                }
            }
        }
        .navigationTitle(model.displayTitle(for: project))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await model.loadConversations(projectId: project.projectId)
        }
        .task(id: project.projectId) {
            await model.loadConversations(projectId: project.projectId)
        }
    }
}

struct ConversationRow: View {
    let conversation: ConversationSummary

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func relativeTime(_ epochMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 8) {
            AgentBadge(agent: conversation.agent)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title.isEmpty ? "未命名会话" : conversation.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(Self.relativeTime(conversation.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if conversation.archived {
                Text("已归档")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if !conversation.resumable {
                Text("不可续聊")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.12), in: Capsule())
                    .foregroundStyle(.red)
            }
        }
    }
}

struct SubagentRow: View {
    let conversation: ConversationSummary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            AgentBadge(agent: conversation.agent)
            Text(conversation.title.isEmpty ? "子会话" : conversation.title)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Text(ConversationRow.relativeTime(conversation.updatedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 20)
    }
}

struct AgentBadge: View {
    let agent: AgentKind

    var body: some View {
        Text(agent.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(agent.tint.opacity(0.18), in: Capsule())
            .foregroundStyle(agent.tint)
    }
}

extension AgentKind {
    var tint: Color {
        switch self {
        case .codex: return .teal
        case .claude: return .orange
        case .grok: return .indigo
        case .deepseek: return .blue
        }
    }
}
