import Foundation
import Network

nonisolated struct TransportShutdownGate: Sendable {
    private var didBegin = false

    mutating func begin() -> Bool {
        guard !didBegin else { return false }
        didBegin = true
        return true
    }
}

nonisolated enum NearbyLifecycleUpdate: Equatable, Sendable {
    case ready
    case waiting(NearbyPreflightIssue)
    case failed(NearbyPreflightIssue)
}

nonisolated final class NearbyLifecycleGate: @unchecked Sendable {
    private enum Outcome {
        case success
        case failure(NearbyPreflightIssue)
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var cancelResource: (@Sendable () -> Void)?
    private var outcome: Outcome?
    private var completions = 0

    var completionCount: Int { lock.withLock { completions } }

    func waitUntilReady(
        start: @escaping @Sendable (@escaping @Sendable (NearbyLifecycleUpdate) -> Void) -> Void,
        cancel: @escaping @Sendable () -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pendingOutcome: Outcome? = lock.withLock {
                    if let outcome { return outcome }
                    self.continuation = continuation
                    cancelResource = cancel
                    return nil
                }
                if let pendingOutcome {
                    Self.resume(continuation, with: pendingOutcome)
                    return
                }
                start { [weak self] update in self?.consume(update) }
                if Task.isCancelled { finish(.failure(.connectionFailed), cancellingResource: true) }
            }
        } onCancel: {
            finish(.failure(.connectionFailed), cancellingResource: true)
        }
    }

    private func consume(_ update: NearbyLifecycleUpdate) {
        switch update {
        case .ready:
            finish(.success, cancellingResource: false)
        case let .waiting(issue), let .failed(issue):
            finish(.failure(issue), cancellingResource: true)
        }
    }

    private func finish(_ outcome: Outcome, cancellingResource: Bool) {
        let actions: (CheckedContinuation<Void, any Error>?, (@Sendable () -> Void)?) = lock.withLock {
            guard self.outcome == nil else { return (nil, nil) }
            self.outcome = outcome
            completions += 1
            let continuation = self.continuation
            self.continuation = nil
            let cancel = cancellingResource ? cancelResource : nil
            cancelResource = nil
            return (continuation, cancel)
        }
        actions.1?()
        if let continuation = actions.0 { Self.resume(continuation, with: outcome) }
    }

    private static func resume(_ continuation: CheckedContinuation<Void, any Error>, with outcome: Outcome) {
        switch outcome {
        case .success: continuation.resume()
        case let .failure(issue): continuation.resume(throwing: issue)
        }
    }
}

actor NearbyTransport: Transport {
    static let serviceType = "_industrialcity._tcp"
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    private let queue: DispatchQueue
    private let serviceName: String?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [GameCore.PlayerID: NWConnection] = [:]
    private var decoders: [GameCore.PlayerID: LengthPrefixedFrameCodec.Decoder] = [:]
    private var terminationRegistry = ConnectionTerminationRegistry()
    private var shutdownGate = TransportShutdownGate()

    init(serviceName: String? = nil, queue: DispatchQueue = .init(label: "IndustrialCity.NearbyTransport")) {
        self.serviceName = serviceName.map(NearbyServiceName.sanitize)
        self.queue = queue
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    nonisolated static func makeParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }

    nonisolated static func makeService(roomID: GameCore.RoomID) -> NWListener.Service {
        var service = NWListener.Service(name: NearbyServiceName.sanitize(roomID.rawValue), type: serviceType)
        service.noAutoRename = true
        return service
    }

    func startHosting(roomID: GameCore.RoomID, port: UInt16?) async throws {
        let parameters = Self.makeParameters()
        let listener: NWListener
        if let port {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw TransportError.invalidPort }
            listener = try NWListener(using: parameters, on: nwPort)
        } else {
            listener = try NWListener(using: parameters)
        }
        listener.service = Self.makeService(roomID: roomID)
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        self.listener = listener
        let gate = NearbyLifecycleGate()
        do {
            try await gate.waitUntilReady(start: { [queue] update in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: update(.ready)
                    case let .waiting(error): update(.waiting(NearbyPreflight.issue(for: error)))
                    case let .failed(error): update(.failed(NearbyPreflight.issue(for: error)))
                    case .cancelled: update(.failed(.connectionFailed))
                    default: break
                    }
                }
                listener.start(queue: queue)
            }, cancel: {
                listener.stateUpdateHandler = nil
                listener.newConnectionHandler = nil
                listener.cancel()
            })
            listener.stateUpdateHandler = nil
        } catch {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            if self.listener === listener { self.listener = nil }
            throw error
        }
    }

    func browse() async throws {
        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: Self.makeParameters()
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint,
                      let room = NearbyRoom(serviceName: name) else { continue }
                self?.continuation.yield(.discovered(.init(rawValue: room.serviceName)))
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func connect(to peer: GameCore.PlayerID) async throws {
        let name = serviceName ?? NearbyServiceName.sanitize(peer.rawValue)
        let endpoint = NWEndpoint.service(name: name, type: Self.serviceType, domain: "local", interface: nil)
        let connection = NWConnection(to: endpoint, using: Self.makeParameters())
        connections[peer] = connection
        terminationRegistry.register(connection, for: peer)
        decoders[peer] = .init()
        receive(on: connection, peer: peer)
        let gate = NearbyLifecycleGate()
        do {
            try await gate.waitUntilReady(start: { [queue] update in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: update(.ready)
                    case let .waiting(error): update(.waiting(NearbyPreflight.issue(for: error)))
                    case let .failed(error): update(.failed(NearbyPreflight.issue(for: error)))
                    case .cancelled: update(.failed(.connectionFailed))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }, cancel: {
                connection.stateUpdateHandler = nil
                connection.cancel()
            })
        } catch {
            connection.stateUpdateHandler = nil
            _ = terminationRegistry.terminate(connection, for: peer)
            connections[peer] = nil
            decoders[peer] = nil
            throw error
        }
        installStateHandler(connection, peer: peer)
        connectionReady(peer: peer, connection: connection)
    }

    func send(_ data: Data, to peer: GameCore.PlayerID) async throws {
        guard let connection = connections[peer] else { throw TransportError.notConnected }
        let framed = try LengthPrefixedFrameCodec.frame(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func disconnect() {
        guard shutdownGate.begin() else { return }
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        connections.values.forEach { $0.stateUpdateHandler = nil; $0.cancel() }
        connections.removeAll()
        decoders.removeAll()
        continuation.finish()
    }

    private func accept(_ connection: NWConnection) {
        let peer = GameCore.PlayerID(rawValue: UUID().uuidString)
        connections[peer] = connection
        terminationRegistry.register(connection, for: peer)
        decoders[peer] = .init()
        installStateHandler(connection, peer: peer)
        receive(on: connection, peer: peer)
        connection.start(queue: queue)
    }

    private func installStateHandler(_ connection: NWConnection, peer: GameCore.PlayerID) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: Task { await self?.connectionReady(peer: peer, connection: connection) }
            case .failed: Task { await self?.terminate(peer: peer, connection: connection, error: .connectionFailed) }
            case .cancelled: Task { await self?.terminate(peer: peer, connection: connection, error: nil) }
            default: break
            }
        }
    }

    private func receive(on connection: NWConnection, peer: GameCore.PlayerID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { await self?.consume(data, complete: complete, error: error, connection: connection, peer: peer) }
        }
    }

    private func consume(_ data: Data?, complete: Bool, error: NWError?, connection: NWConnection, peer: GameCore.PlayerID) {
        guard terminationRegistry.contains(connection, for: peer) else { return }
        do {
            if let data {
                var decoder = decoders[peer] ?? .init()
                for frame in try decoder.append(data) { continuation.yield(.received(frame, from: peer)) }
                guard terminationRegistry.contains(connection, for: peer) else { return }
                decoders[peer] = decoder
            }
        } catch let transportError as TransportError {
            terminate(peer: peer, connection: connection, error: transportError)
            return
        } catch {
            terminate(peer: peer, connection: connection, error: .connectionFailed)
            return
        }
        if complete || error != nil {
            terminate(peer: peer, connection: connection, error: error == nil ? nil : .connectionFailed)
        } else {
            guard terminationRegistry.contains(connection, for: peer) else { return }
            receive(on: connection, peer: peer)
        }
    }

    private func connectionReady(peer: GameCore.PlayerID, connection: NWConnection) {
        guard terminationRegistry.contains(connection, for: peer) else { return }
        continuation.yield(.connected(peer))
    }

    private func terminate(peer: GameCore.PlayerID, connection: NWConnection, error: TransportError?) {
        guard terminationRegistry.terminate(connection, for: peer) else { return }
        connection.stateUpdateHandler = nil
        connections[peer] = nil
        decoders[peer] = nil
        continuation.yield(.disconnected(peer, error))
        connection.cancel()
    }
}
