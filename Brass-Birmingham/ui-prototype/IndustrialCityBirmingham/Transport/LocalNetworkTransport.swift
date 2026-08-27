import Foundation
import Network

nonisolated struct ConnectionTerminationRegistry: Sendable {
    private struct Entry: @unchecked Sendable { let connection: AnyObject }
    private var entries: [GameCore.PlayerID: Entry] = [:]

    mutating func register(_ connection: AnyObject, for peer: GameCore.PlayerID) {
        entries[peer] = .init(connection: connection)
    }

    func contains(_ connection: AnyObject, for peer: GameCore.PlayerID) -> Bool {
        entries[peer]?.connection === connection
    }

    mutating func terminate(_ connection: AnyObject, for peer: GameCore.PlayerID) -> Bool {
        guard contains(connection, for: peer) else { return false }
        entries[peer] = nil
        return true
    }
}

actor LocalNetworkTransport: Transport {
    // Simulator-only deterministic harness. Production nearby play uses NearbyTransport.
    static let serviceType = "_industrialcity-dev._tcp"
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    private let queue: DispatchQueue
    private let serviceName: String?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [GameCore.PlayerID: NWConnection] = [:]
    private var decoders: [GameCore.PlayerID: LengthPrefixedFrameCodec.Decoder] = [:]
    private var terminationRegistry = ConnectionTerminationRegistry()
    private var hostingContinuation: CheckedContinuation<Void, any Error>?
    private var connectionContinuations: [GameCore.PlayerID: CheckedContinuation<Void, any Error>] = [:]

    init(serviceName: String? = nil, queue: DispatchQueue = .init(label: "IndustrialCity.LocalNetworkTransport")) {
        self.serviceName = serviceName
        self.queue = queue
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    func startHosting(roomID: GameCore.RoomID, port: UInt16?) async throws {
        let parameters = NWParameters.tcp
        let listener: NWListener
        if let port {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw TransportError.invalidPort }
            listener = try NWListener(using: parameters, on: nwPort)
        } else {
            listener = try NWListener(using: parameters)
        }
        listener.service = .init(name: roomID.rawValue, type: Self.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let listener else { return }
            Task { await self?.listenerStateChanged(state, listener: listener) }
        }
        self.listener = listener
        try await withCheckedThrowingContinuation { continuation in
            hostingContinuation = continuation
            listener.start(queue: queue)
        }
    }

    func browse() async throws {
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                self?.continuation.yield(.discovered(.init(rawValue: name)))
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func connect(to peer: GameCore.PlayerID) async throws {
        let endpoint = NWEndpoint.service(name: serviceName ?? peer.rawValue, type: Self.serviceType, domain: "local", interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)
        connections[peer] = connection
        terminationRegistry.register(connection, for: peer)
        decoders[peer] = .init()
        installStateHandler(connection, peer: peer)
        receive(on: connection, peer: peer)
        try await withCheckedThrowingContinuation { continuation in
            connectionContinuations[peer] = continuation
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data, to peer: GameCore.PlayerID) async throws {
        guard let connection = connections[peer] else { throw TransportError.notConnected }
        let framed = try LengthPrefixedFrameCodec.frame(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func disconnect() async {
        hostingContinuation?.resume(throwing: TransportError.connectionFailed)
        hostingContinuation = nil
        connectionContinuations.values.forEach { $0.resume(throwing: TransportError.connectionFailed) }
        connectionContinuations.removeAll()
        listener?.cancel(); browser?.cancel()
        connections.values.forEach { $0.stateUpdateHandler = nil; $0.cancel() }
        connections.removeAll(); decoders.removeAll()
        continuation.finish()
    }

    private func accept(_ connection: NWConnection) {
        let peer = GameCore.PlayerID(rawValue: UUID().uuidString)
        connections[peer] = connection; decoders[peer] = .init()
        terminationRegistry.register(connection, for: peer)
        installStateHandler(connection, peer: peer); receive(on: connection, peer: peer)
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
            terminate(peer: peer, connection: connection, error: transportError); return
        } catch { terminate(peer: peer, connection: connection, error: .connectionFailed); return }
        if complete || error != nil {
            terminate(peer: peer, connection: connection, error: error == nil ? nil : .connectionFailed)
        } else {
            guard terminationRegistry.contains(connection, for: peer) else { return }
            receive(on: connection, peer: peer)
        }
    }

    private func connectionReady(peer: GameCore.PlayerID, connection: NWConnection) {
        guard terminationRegistry.contains(connection, for: peer) else { return }
        connectionContinuations.removeValue(forKey: peer)?.resume()
        continuation.yield(.connected(peer))
    }

    private func terminate(peer: GameCore.PlayerID, connection: NWConnection, error: TransportError?) {
        guard terminationRegistry.terminate(connection, for: peer) else { return }
        connection.stateUpdateHandler = nil
        connectionContinuations.removeValue(forKey: peer)?.resume(
            throwing: error ?? TransportError.connectionFailed
        )
        connections[peer] = nil; decoders[peer] = nil
        continuation.yield(.disconnected(peer, error))
        connection.cancel()
    }

    private func listenerStateChanged(_ state: NWListener.State, listener: NWListener) {
        guard self.listener === listener else { return }
        switch state {
        case .ready:
            hostingContinuation?.resume()
            hostingContinuation = nil
        case .failed, .cancelled:
            hostingContinuation?.resume(throwing: TransportError.connectionFailed)
            hostingContinuation = nil
        default:
            break
        }
    }
}
