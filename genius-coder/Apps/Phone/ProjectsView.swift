import SwiftUI
import PhoneProtocol

struct ProjectsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.visibleProjects.isEmpty {
                        Text(
                            model.projects.isEmpty
                                ? "还没有项目。下拉刷新会向 bridge 要一次索引。"
                                : "没有符合筛选条件的项目。"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                    }
                    ForEach(model.visibleProjects, id: \.projectId) { project in
                        NavigationLink {
                            ConversationListView(project: project)
                        } label: {
                            ProjectRow(
                                project: project,
                                title: model.displayTitle(for: project)
                            )
                        }
                    }
                } header: {
                    VStack(spacing: 0) {
            TsnetLoginBanner()
            ConnectionBanner()
        }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("项目")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Picker("Agent 筛选", selection: $model.agentFilter) {
                        Text("全部").tag(AgentFilter.all)
                        Text("Codex").tag(AgentFilter.codex)
                        Text("Claude").tag(AgentFilter.claude)
                        Text("Grok").tag(AgentFilter.grok)
                        Text("DeepSeek").tag(AgentFilter.deepseek)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .refreshable {
                await model.refreshProjects()
            }
        }
    }
}

/// 常驻连接状态：LAN / Tailscale / 断开。断开时仍可翻本地缓存。
struct TsnetLoginBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let url = model.tsnetLoginURL {
            VStack(spacing: 6) {
                Text("首次使用远程连接，需要登录一次 Tailscale 账号")
                    .font(.footnote)
                Link("打开登录页面", destination: url)
                    .font(.footnote.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.15))
        }
    }
}

struct ConnectionBanner: View {
    @EnvironmentObject private var model: AppModel

    private var tint: Color {
        switch model.connection {
        case .lan: return .green
        case .tailscale: return .blue
        case .disconnected: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(model.connection.rawValue)
                .font(.footnote.weight(.medium))
            if let detail = model.connectionDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.connection == .disconnected {
                Button("重连") {
                    Task { await model.reconnect() }
                }
                .font(.caption)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if model.connection == .disconnected {
                Task { await model.reconnect() }
            }
        }
    }
}

struct ProjectRow: View {
    let project: ProjectSummary
    let title: String

    private var totalSessions: Int {
        project.counts.values.reduce(0, +)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if project.missing {
                    Text("目录不存在")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if totalSessions == 0 {
                    Text("无会话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                ForEach(AgentKind.allCases, id: \.self) { agent in
                    let count = project.counts[agent.rawValue] ?? 0
                    if count > 0 {
                        HStack(spacing: 2) {
                            Circle()
                                .fill(agent.tint)
                                .frame(width: 6, height: 6)
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(agent.tint)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(agent.tint.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
    }
}
