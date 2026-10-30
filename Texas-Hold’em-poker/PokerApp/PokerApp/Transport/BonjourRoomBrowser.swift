import Foundation
import Network

/// 房间显示名 → Bonjour 实例名（ASCII 大写、分隔符收敛、≤40 字符、空名兜底）。
nonisolated enum RoomName {
    static func sanitize(_ input: String) -> String {
        let folded = input.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: .init(identifier: "en_US_POSIX"))
        let scalars = folded.uppercased().unicodeScalars.map { scalar -> Character in
            Character((CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII) ? String(scalar) : "-")
        }
        let components = String(scalars).split(separator: "-", omittingEmptySubsequences: true)
        let normalized = components.joined(separator: "-")
        return String((normalized.isEmpty ? "ROOM" : normalized).prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// 搜到的房间：serviceName 即 roomID（房主建房的 Bonjour 实例名）。
nonisolated struct RoomListing: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let serviceName: String
    var roomID: String { serviceName }
    init(id: String, serviceName: String) {
        self.id = id
        self.serviceName = serviceName
    }
}

nonisolated enum RoomBrowseState: Equatable, Sendable {
    case searching
    case found([RoomListing])
    case empty
    case failed(NearbyIssue)
}

nonisolated enum RoomBrowserUpdate: Equatable, Sendable {
    case ready
    case added(RoomListing)
    case removed(String)
    case failed(NearbyIssue)
}

nonisolated protocol RoomBrowsing: Sendable {
    var updates: AsyncStream<RoomBrowserUpdate> { get }
    func start()
    func cancel()
}

/// 房间浏览（可注入驱动以便测试）。
actor BonjourRoomBrowser {
    nonisolated let states: AsyncStream<RoomBrowseState>
    private nonisolated let continuation: AsyncStream<RoomBrowseState>.Continuation
    private let driver: any RoomBrowsing
    private var roomsByID: [String: RoomListing] = [:]
    private var processingTask: Task<Void, Never>?
    private var didCancel = false

    init(driver: any RoomBrowsing = NWRoomBrowserDriver()) {
        self.driver = driver
        (states, continuation) = AsyncStream.makeStream(of: RoomBrowseState.self)
    }

    func start() {
        guard processingTask == nil, !didCancel else { return }
        continuation.yield(.searching)
        processingTask = Task { [weak self, driver] in
            for await update in driver.updates {
                guard !Task.isCancelled else { return }
                await self?.consume(update)
            }
        }
        driver.start()
    }

    func cancel() {
        guard !didCancel else { return }
        didCancel = true
        processingTask?.cancel()
        processingTask = nil
        driver.cancel()
        continuation.finish()
    }

    private var sortedRooms: [RoomListing] {
        Dictionary(grouping: roomsByID.values, by: \.serviceName)
            .values.compactMap(\.first)
            .sorted { $0.serviceName.localizedStandardCompare($1.serviceName) == .orderedAscending }
    }

    private func consume(_ update: RoomBrowserUpdate) {
        switch update {
        case .ready:
            continuation.yield(roomsByID.isEmpty ? .empty : .found(sortedRooms))
        case let .added(listing):
            guard roomsByID[listing.id] == nil else { return }
            let wasDisplayed = roomsByID.values.contains { $0.serviceName == listing.serviceName }
            roomsByID[listing.id] = listing
            guard !wasDisplayed else { return }
            continuation.yield(.found(sortedRooms))
        case let .removed(id):
            guard let removed = roomsByID.removeValue(forKey: id) else { return }
            guard !roomsByID.values.contains(where: { $0.serviceName == removed.serviceName }) else { return }
            continuation.yield(roomsByID.isEmpty ? .empty : .found(sortedRooms))
        case let .failed(issue):
            continuation.yield(.failed(issue))
        }
    }
}

/// 真实 NWBrowser 驱动。
nonisolated final class NWRoomBrowserDriver: RoomBrowsing, @unchecked Sendable {
    nonisolated let updates: AsyncStream<RoomBrowserUpdate>
    private let continuation: AsyncStream<RoomBrowserUpdate>.Continuation
    private let queue = DispatchQueue(label: "PokerApp.NWRoomBrowserDriver")
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var knownIDs: Set<String> = []
    private var didStart = false
    private var didCancel = false

    init() {
        (updates, continuation) = AsyncStream.makeStream(of: RoomBrowserUpdate.self)
    }

    func start() {
        let browser: NWBrowser? = lock.withLock {
            guard !didStart, !didCancel else { return nil }
            didStart = true
            let browser = NWBrowser(for: .bonjour(type: NearbyTransport.serviceType, domain: nil),
                                    using: NearbyTransport.makeParameters())
            self.browser = browser
            return browser
        }
        guard let browser else { return }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.continuation.yield(.ready)
            case let .failed(error): self?.continuation.yield(.failed(NearbyPreflight.issue(for: error)))
            case let .waiting(error): self?.continuation.yield(.failed(NearbyPreflight.issue(for: error)))
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            // 全量快照差分：房间消失也要发 .removed（spec §5 名册出现/消失）
            let current = results.compactMap { result -> (id: String, name: String)? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return (name + "|" + result.endpoint.debugDescription, name)
            }
            let changes: [RoomBrowserUpdate] = lock.withLock {
                var updates: [RoomBrowserUpdate] = []
                let currentIDs = Set(current.map(\.id))
                for id in self.knownIDs.subtracting(currentIDs) { updates.append(.removed(id)) }
                for entry in current where !self.knownIDs.contains(entry.id) {
                    updates.append(.added(RoomListing(id: entry.id, serviceName: entry.name)))
                }
                self.knownIDs = currentIDs
                return updates
            }
            changes.forEach { self.continuation.yield($0) }
        }
        browser.start(queue: queue)
    }

    func cancel() {
        let browser: NWBrowser? = lock.withLock {
            guard !didCancel else { return nil }
            didCancel = true
            let current = self.browser
            self.browser = nil
            return current
        }
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        continuation.finish()
    }
}
