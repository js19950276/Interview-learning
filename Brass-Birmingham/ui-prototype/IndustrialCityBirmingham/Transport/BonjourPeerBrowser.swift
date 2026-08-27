import Foundation
import Network

nonisolated enum NearbyServiceName {
    static func sanitize(_ input: String) -> String {
        let folded = input.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
        let scalars = folded.uppercased().unicodeScalars.map { scalar -> Character in
            Character((CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII) ? String(scalar) : "-")
        }
        let components = String(scalars).split(separator: "-", omittingEmptySubsequences: true)
        let normalized = components.joined(separator: "-")
        return String((normalized.isEmpty ? "ROOM" : normalized).prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

nonisolated struct NearbyRoom: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let serviceName: String

    init?(serviceName: String) {
        guard !serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let sanitized = NearbyServiceName.sanitize(serviceName)
        id = sanitized
        self.serviceName = sanitized
    }
}

nonisolated struct BonjourServiceInstance: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let room: NearbyRoom

    init?(endpointID: String, serviceName: String) {
        guard !endpointID.isEmpty, let room = NearbyRoom(serviceName: serviceName) else { return nil }
        id = endpointID
        self.room = room
    }
}

nonisolated struct BonjourResultSnapshot: Equatable, Hashable, Sendable {
    let name: String
    let type: String
    let domain: String
    let endpointInterface: String?
    let resultInterfaces: Set<String>

    init(name: String, type: String, domain: String, endpointInterface: String?, resultInterfaces: Set<String>) {
        self.name = name
        self.type = type
        self.domain = domain
        self.endpointInterface = endpointInterface
        self.resultInterfaces = resultInterfaces
    }

    var instance: BonjourServiceInstance? {
        let endpointID = [
            name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX")).lowercased(),
            type.lowercased(), domain.lowercased(), endpointInterface ?? "",
        ].joined(separator: "\u{1F}")
        return BonjourServiceInstance(endpointID: endpointID, serviceName: name)
    }
}

nonisolated struct BonjourResultTracker: Sendable {
    private var knownByID: [String: BonjourServiceInstance] = [:]

    mutating func updates(for snapshots: [BonjourResultSnapshot]) -> [BonjourBrowserUpdate] {
        var nextByID: [String: BonjourServiceInstance] = [:]
        snapshots.compactMap(\.instance).forEach { nextByID[$0.id] = $0 }
        let knownIDs = Set(knownByID.keys)
        let nextIDs = Set(nextByID.keys)
        let removed = knownIDs.subtracting(nextIDs).sorted().map(BonjourBrowserUpdate.removed)
        let added = nextIDs.subtracting(knownIDs).sorted().compactMap { nextByID[$0] }.map(BonjourBrowserUpdate.added)
        knownByID = nextByID
        return removed + added
    }
}

nonisolated enum BonjourBrowserUpdate: Equatable, Sendable {
    case ready
    case added(BonjourServiceInstance)
    case removed(String)
    case failed(NearbyPreflightIssue)
}

nonisolated enum NearbyBrowseState: Equatable, Sendable {
    case searching
    case found([NearbyRoom])
    case empty
    case failed(NearbyPreflightIssue)
}

nonisolated protocol BonjourBrowserDriving: Sendable {
    var updates: AsyncStream<BonjourBrowserUpdate> { get }
    func start()
    func cancel()
}

actor BonjourPeerBrowser {
    nonisolated let states: AsyncStream<NearbyBrowseState>
    private nonisolated let continuation: AsyncStream<NearbyBrowseState>.Continuation
    private let driver: any BonjourBrowserDriving
    private var instancesByID: [String: BonjourServiceInstance] = [:]
    private var processingTask: Task<Void, Never>?
    private var didCancel = false

    var rooms: [NearbyRoom] { sortedRooms }

    init(driver: some BonjourBrowserDriving = NetworkBonjourBrowserDriver()) {
        self.driver = driver
        (states, continuation) = AsyncStream.makeStream(of: NearbyBrowseState.self)
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

    private var sortedRooms: [NearbyRoom] {
        Dictionary(grouping: instancesByID.values, by: \.room.id)
            .values
            .compactMap { $0.first?.room }
            .sorted { $0.serviceName.localizedStandardCompare($1.serviceName) == .orderedAscending }
    }

    private func consume(_ update: BonjourBrowserUpdate) {
        switch update {
        case .ready:
            continuation.yield(instancesByID.isEmpty ? .empty : .found(sortedRooms))
        case let .added(instance):
            guard instancesByID[instance.id] == nil else { return }
            let wasDisplayed = instancesByID.values.contains { $0.room.id == instance.room.id }
            instancesByID[instance.id] = instance
            guard !wasDisplayed else { return }
            continuation.yield(.found(sortedRooms))
        case let .removed(id):
            guard let removed = instancesByID.removeValue(forKey: id) else { return }
            guard !instancesByID.values.contains(where: { $0.room.id == removed.room.id }) else { return }
            continuation.yield(instancesByID.isEmpty ? .empty : .found(sortedRooms))
        case let .failed(issue):
            continuation.yield(.failed(issue))
        }
    }
}

nonisolated final class NetworkBonjourBrowserDriver: BonjourBrowserDriving, @unchecked Sendable {
    nonisolated let updates: AsyncStream<BonjourBrowserUpdate>
    private let continuation: AsyncStream<BonjourBrowserUpdate>.Continuation
    private let queue = DispatchQueue(label: "IndustrialCity.NearbyBonjourBrowser")
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var resultTracker = BonjourResultTracker()
    private var didStart = false
    private var didCancel = false

    init() {
        (updates, continuation) = AsyncStream.makeStream(of: BonjourBrowserUpdate.self)
    }

    func start() {
        let browser: NWBrowser? = lock.withLock {
            guard !didStart, !didCancel else { return nil }
            didStart = true
            let browser = NWBrowser(
                for: .bonjour(type: NearbyTransport.serviceType, domain: nil),
                using: NearbyTransport.makeParameters()
            )
            self.browser = browser
            return browser
        }
        guard let browser else { return }
        browser.stateUpdateHandler = { [weak self] state in self?.consume(state) }
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.consume(results) }
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

    private func consume(_ state: NWBrowser.State) {
        switch state {
        case .ready: continuation.yield(.ready)
        case let .failed(error): continuation.yield(.failed(NearbyPreflight.issue(for: error)))
        case let .waiting(error): continuation.yield(.failed(NearbyPreflight.issue(for: error)))
        default: break
        }
    }

    private func consume(_ results: Set<NWBrowser.Result>) {
        let snapshots = results.compactMap { result -> BonjourResultSnapshot? in
            guard case let .service(name, type, domain, endpointInterface) = result.endpoint else { return nil }
            return BonjourResultSnapshot(
                name: name, type: type, domain: domain,
                endpointInterface: endpointInterface?.name,
                resultInterfaces: Set(result.interfaces.map(\.name))
            )
        }
        let changes = lock.withLock { resultTracker.updates(for: snapshots) }
        changes.forEach { continuation.yield($0) }
    }
}
