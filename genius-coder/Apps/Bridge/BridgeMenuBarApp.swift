import SwiftUI
import BridgeCore
import PhoneProtocol

// Menu bar bridge (spec: Mac 进程模型 — LSUIElement, MenuBarExtra, no
// KeepAlive; quitting stays quit until the next login).

@main
struct BridgeMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = BridgeModel.shared

    var body: some Scene {
        MenuBarExtra("genius-coder", systemImage: model.statusIcon) {
            BridgeMenuContent()
                .environmentObject(model)
        }
        Settings {
            BridgeSettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        BridgeModel.shared.start()
    }
}

@MainActor
final class BridgeModel: ObservableObject {
    static let shared = BridgeModel()

    @Published var port: UInt16?
    @Published var paired: Bool = false
    @Published var listenerKinds: [String] = []
    @Published var sendSwitches = SendSwitches()
    @Published var allowlist: Allowlist
    @Published var lastError: String?
    @Published var binaryStatus: [(String, Bool)] = []
    @Published var liveSessions: Int = 0
    @Published var pairingQR: PairingQRPayload?

    let app: BridgeApp
    private var refreshTimer: Timer?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("genius-coder")
        app = BridgeApp(appSupport: support)
        allowlist = Allowlist.load(from: support)
        sendSwitches = app.conversations.sendSwitches()
    }

    func start() {
        port = app.startNetwork()
        paired = app.server.pairingStore.current.device != nil
        listenerKinds = InterfaceLocator().currentBindAddresses().map(\.kind.rawValue)
        refreshBinaryStatus()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatus()
            }
        }
    }

    func refreshStatus() {
        paired = app.server.pairingStore.current.device != nil
        sendSwitches = app.conversations.sendSwitches()
        liveSessions = (app.conversations.grok?.liveSessionCount() ?? 0)
            + (app.conversations.dsh?.liveSessionCount() ?? 0)
            + (app.conversations.claude?.liveSessionCount() ?? 0)
    }

    func refreshBinaryStatus() {
        let binaries = AgentBinaries()
        binaryStatus = [
            ("Codex", FileManager.default.fileExists(atPath: binaries.codex)),
            ("Grok", FileManager.default.fileExists(atPath: binaries.grok)),
            ("Claude", FileManager.default.fileExists(atPath: binaries.claude)),
            ("DeepSeek", FileManager.default.fileExists(atPath: binaries.dsh)),
        ]
    }

    var statusIcon: String {
        if port == nil { return "antenna.radiowaves.left.and.right.slash" }
        return paired ? "antenna.radiowaves.left.and.right" : "qrcode"
    }

    func makePairingQR() -> PairingQRPayload? {
        app.server.makePairingQR()
    }

    func toggleSend(_ agent: AgentKind, _ on: Bool) {
        app.conversations.setSendSwitch(agent, on, saveTo: app.appSupport)
        sendSwitches = app.conversations.sendSwitches()
    }

    func revokeDevice() {
        app.server.pairingStore.revokeDevice()
        paired = false
    }

    func refreshIndex() {
        app.indexStore.refresh()
    }

    // MARK: allowlist seeding prompt (asked exactly once, spec: Indexer)

    var needsSeedPrompt: Bool {
        !allowlist.seedPromptAnswered
    }

    func answerSeedPrompt(allow: Bool) {
        var next = allowlist
        if allow {
            let seeder = AllowlistSeeder()
            let roots = seeder.candidateRoots(from: app.indexStore.knownCwds())
            next = seeder.applyConfirmation(next, roots: roots)
        } else {
            next = AllowlistSeeder().applyRefusal(next)
        }
        next.save(to: app.appSupport)
        allowlist = next
        app.indexStore.updateAllowlist(next)
        app.indexStore.refresh()
    }

    func addAllowlistRoot(_ path: String) -> Bool {
        guard let canonical = Allowlist.normalizeRoot(path, explicitRootAllowed: false) else { return false }
        var next = allowlist
        if !next.roots.contains(canonical) {
            next.roots.append(canonical)
            next.save(to: app.appSupport)
            allowlist = next
            app.indexStore.updateAllowlist(next)
            app.indexStore.refresh()
        }
        return true
    }

    func removeAllowlistRoot(_ path: String) {
        var next = allowlist
        next.roots.removeAll { $0 == path }
        next.save(to: app.appSupport)
        allowlist = next
        app.indexStore.updateAllowlist(next)
        app.indexStore.refresh()
    }
}

struct BridgeMenuContent: View {
    @EnvironmentObject var model: BridgeModel

    var body: some View {
        if model.needsSeedPrompt {
            seedPromptSection
        }
        if model.port == nil {
            Text("未监听（无可用网卡）")
        } else {
            Text("端口 \(model.port ?? 0) · \(model.listenerKinds.joined(separator: "+"))")
        }
        if model.paired {
            Text("已配对设备")
        } else {
            Button("配对新手机…") {
                model.pairingQR = model.makePairingQR()
            }
        }
        Divider()
        ForEach(AgentKind.allCases, id: \.self) { agent in
            Toggle("允许发送 · \(agent.displayName)", isOn: Binding(
                get: { model.sendSwitches.isEnabled(agent) },
                set: { model.toggleSend(agent, $0) }
            ))
        }
        Divider()
        Text("活会话：\(model.liveSessions)")
        ForEach(model.binaryStatus, id: \.0) { entry in
            Text("\(entry.0)：\(entry.1 ? "已找到" : "缺失")")
        }
        Divider()
        Button("刷新索引") { model.refreshIndex() }
        Button("设置…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        Divider()
        Button("退出 genius-coder") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var seedPromptSection: some View {
        Group {
            Text("把已有会话的项目目录加入允许列表？")
            HStack {
                Button("允许") { model.answerSeedPrompt(allow: true) }
                Button("不，别再问") { model.answerSeedPrompt(allow: false) }
            }
            Divider()
        }
    }
}

struct BridgeSettingsView: View {
    @EnvironmentObject var model: BridgeModel
    @State private var newRoot = ""
    @State private var qrImage: NSImage?

    var body: some View {
        TabView {
            allowlistTab.tabItem { Label("允许列表", systemImage: "folder.badge.gearshape") }
            pairingTab.tabItem { Label("配对", systemImage: "qrcode") }
            aboutTab.tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 420)
    }

    private var allowlistTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("允许列表（规范绝对目录，按路径分量匹配）")
                .font(.headline)
            List {
                ForEach(model.allowlist.roots, id: \.self) { root in
                    HStack {
                        Text(root)
                        Spacer()
                        Button("移除") { model.removeAllowlistRoot(root) }
                    }
                }
            }
            HStack {
                TextField("/Users/me/code", text: $newRoot)
                Button("添加") {
                    if model.addAllowlistRoot(newRoot) {
                        newRoot = ""
                    }
                }
            }
            Text("拒绝相对路径与 /；同名兄弟目录永不会匹配。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var pairingTab: some View {
        VStack(spacing: 12) {
            if let qr = model.pairingQR {
                Text("一次性二维码（5 分钟内有效，仅此一次）")
                if let image = QRCodeRenderer.render(qr) {
                    Image(nsImage: image).interpolation(.none)
                        .resizable().scaledToFit().frame(width: 220, height: 220)
                } else {
                    Text("二维码渲染不可用：JSON 如下")
                    Text(String(data: (try? qr.encodedJSON()) ?? Data(), encoding: .utf8) ?? "")
                        .font(.system(size: 9, design: .monospaced))
                        .frame(maxWidth: .infinity)
                }
                Button("重新生成") { model.pairingQR = model.makePairingQR() }
            } else {
                Text("生成一次性配对二维码，用 iPhone 扫码。")
                Button("生成二维码") { model.pairingQR = model.makePairingQR() }
            }
            Divider()
            Button("撤销已配对设备", role: .destructive) { model.revokeDevice() }
        }
        .padding()
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("genius-coder bridge \(BridgeInfo.version)")
            Text("Bundle: com.local.geniuscoder.bridge")
            Text("Bonjour: _geniuscoder._tcp")
            Text("发送开关默认关闭；打开前请确认批准、写入者排除、防睡眠与断线失败关闭已就绪。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// Minimal QR rendering via CoreImage (no third-party dependency).
enum QRCodeRenderer {
    static func render(_ payload: PairingQRPayload) -> NSImage? {
        guard let data = try? payload.encodedJSON() else { return nil }
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
