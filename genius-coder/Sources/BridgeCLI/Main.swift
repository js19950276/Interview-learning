import Foundation
import BridgeCore
import PhoneProtocol

// Headless debug entry for the bridge. Never a product surface (spec
// Non-Goals); it exists so the index and adapters can be exercised without
// the menu bar app.
let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "help"

func runAsync<T>(_ body: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached {
        let value = await body()
        box.set(value)
        semaphore.signal()
    }
    semaphore.wait()
    return box.get()!
}

final class ResultBox<T>: @unchecked Sendable {
    private var value: T?
    private let lock = NSLock()
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}

func appSupport() -> URL {
    let override = ProcessInfo.processInfo.environment["GENIUS_CODER_HOME"]
    if let override {
        return URL(fileURLWithPath: override)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("genius-coder")
}

switch command {
case "scan":
    let support = appSupport()
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let allowlist = Allowlist.load(from: support)
    // Without an answered prompt, scan in "everything" mode for debugging:
    // allowRoot mirrors what the menu bar would seed after confirmation.
    var effective = allowlist
    if !allowlist.seedPromptAnswered {
        effective = Allowlist(roots: allowlist.roots, allowRoot: true, seededFromSessions: false, seedPromptAnswered: false)
    }
    let store = IndexStore(appSupportDirectory: support, allowlist: effective)
    let start = Date()
    store.refresh()
    let elapsed = Date().timeIntervalSince(start)
    let projects = store.projects(filter: .all)
    print("indexed in \(String(format: "%.0f", elapsed * 1000)) ms — \(projects.count) projects")
    for project in projects.prefix(30) {
        let counts = project.counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("  \(project.displayName) [\(counts)]\(project.missing ? " (missing)" : "")")
    }
    if let first = projects.first {
        let conversations = store.conversations(projectId: first.projectId, filter: .all, limit: 10)
        print("first project conversations (\(conversations.count)):")
        for conversation in conversations {
            print("  [\(conversation.agent.rawValue)] \(conversation.title) — resumable=\(conversation.resumable) err=\(conversation.resumableError ?? "-")")
        }
    }
case "serve":
    let support = appSupport()
    let app = BridgeApp(appSupport: support)
    let port = app.startNetwork() ?? 0
    if port == 0 {
        FileHandle.standardError.write("failed to listen (no eligible interface)\n".data(using: .utf8)!)
        exit(1)
    }
    if let qr = app.server.makePairingQR() {
        let lanHosts = qr.hosts.filter { $0.kind == "lan" }.map(\.address)
        print("genius-coder bridge — port \(port) on \(lanHosts.joined(separator: ", ")))")
        print("One-time pairing token, valid 5 minutes, single use. Scan with the phone:")
        if let art = TerminalQR.render(qr) {
            print(art)
        }
        // JSON fallback for terminals that mangle blocks.
        let json = (try? qr.encodedJSON()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        print("If the code does not scan, paste this JSON into the app's manual pairing field:")
        print(json)
    } else {
        print("listening on port \(port); QR unavailable")
    }
    if let tsnet = app.tsnet {
        print("Embedded Tailscale (tsnet) starting…")
        let status: TsnetSupervisor.Status = runAsync { await tsnet.start() }
        if let url = status.loginURL {
            print("First-time login, open ONCE in a browser on this Mac:")
            print(url)
        }
        if let ip = status.tailscaleIP {
            print("tsnet READY: \(ip) — included in the QR below")
            if let qr2 = app.server.makePairingQR(), let art = TerminalQR.render(qr2) {
                print(art)
            }
        } else if let error = status.lastError {
            print("tsnet unavailable: \(error)")
        }
    }
    print("Ctrl-C to stop")
    Thread.sleep(forTimeInterval: .infinity)
case "help", "-h", "--help":
    print("""
    genius-bridge-cli \(BridgeInfo.version)
    commands:
      scan        run all indexers against the real stores and print the project list
      serve       run the bridge headless (TLS listener, no menu bar)
    """)
default:
    print("unknown command \(command); try 'help'")
    exit(64)
}
