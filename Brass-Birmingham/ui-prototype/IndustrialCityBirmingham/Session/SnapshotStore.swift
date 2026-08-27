import CryptoKit
import Foundation
import Security

nonisolated enum SessionArchiveRole: String, Codable, Equatable, Sendable {
    case host
    case guest
}

nonisolated struct RoomTokenReference: Codable, Equatable, Hashable, Sendable {
    let roomID: GameCore.RoomID
    let playerID: GameCore.PlayerID
}

nonisolated struct RecoverableSessionReference: Codable, Equatable, Hashable, Sendable, Identifiable {
    let roomID: GameCore.RoomID
    let playerID: GameCore.PlayerID
    let role: SessionArchiveRole
    let rulesetVersion: String

    init(
        roomID: GameCore.RoomID,
        playerID: GameCore.PlayerID,
        role: SessionArchiveRole,
        rulesetVersion: String = "rules-v1"
    ) {
        self.roomID = roomID
        self.playerID = playerID
        self.role = role
        self.rulesetVersion = rulesetVersion
    }

    var id: String { "\(role.rawValue):\(roomID.rawValue):\(playerID.rawValue)" }
}

nonisolated struct GuestSessionArchive: Codable, Equatable, Sendable {
    let snapshot: GameCore.ViewSnapshot
    let eventWindow: [SessionProtocol.SessionEnvelope]
    let tokenReference: RoomTokenReference
    let hostPlayerID: GameCore.PlayerID
}

nonisolated struct PersistedAuthoritativePlayer: Codable, Equatable, Sendable {
    let id: GameCore.PlayerID
    let hand: [String]
}

nonisolated struct PersistedAuthoritativeGameState: Codable, Equatable, Sendable {
    let roomID: GameCore.RoomID
    var players: [PersistedAuthoritativePlayer]
    var activePlayerID: GameCore.PlayerID
    var turn: Int
    var actionNumber: Int
    var authoritativeVersion: GameCore.AuthoritativeVersion
    var discardPile: [String]

    init(_ state: GameCore.AuthoritativeGameState) {
        roomID = state.roomID
        players = state.players.map { .init(id: $0.id, hand: $0.hand) }
        activePlayerID = state.activePlayerID
        turn = state.turn
        actionNumber = state.actionNumber
        authoritativeVersion = state.authoritativeVersion
        discardPile = state.discardPile
    }
}

nonisolated struct HostSessionArchive: Codable, Equatable, Sendable {
    let authoritativeState: PersistedAuthoritativeGameState
    let gameState: GameCore.GameState?
    let eventWindows: [GameCore.PlayerID: [SessionProtocol.SessionEnvelope]]
    let tokenReferences: [RoomTokenReference]
    let peersNeedingRecovery: Set<GameCore.PlayerID>

    init(
        authoritativeState: PersistedAuthoritativeGameState,
        gameState: GameCore.GameState,
        eventWindows: [GameCore.PlayerID: [SessionProtocol.SessionEnvelope]],
        tokenReferences: [RoomTokenReference],
        peersNeedingRecovery: Set<GameCore.PlayerID>
    ) {
        self.authoritativeState = authoritativeState
        self.gameState = gameState
        self.eventWindows = eventWindows
        self.tokenReferences = tokenReferences
        self.peersNeedingRecovery = peersNeedingRecovery
    }
}

nonisolated enum SessionArchivePayload: Codable, Equatable, Sendable {
    case host(HostSessionArchive)
    case guest(GuestSessionArchive)
}

nonisolated struct SessionArchive: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let rulesetVersion: String
    let roomID: GameCore.RoomID
    let recipientID: GameCore.PlayerID
    let role: SessionArchiveRole
    let authoritativeVersion: GameCore.AuthoritativeVersion
    let commitSequence: UInt64
    let payload: SessionArchivePayload

    static func guest(
        protocolVersion: Int,
        rulesetVersion: String,
        hostPlayerID: GameCore.PlayerID,
        snapshot: GameCore.ViewSnapshot,
        eventWindow: [SessionProtocol.SessionEnvelope],
        tokenReference: RoomTokenReference,
        commitSequence: UInt64
    ) -> SessionArchive {
        SessionArchive(
            protocolVersion: protocolVersion,
            rulesetVersion: rulesetVersion,
            roomID: snapshot.roomID,
            recipientID: snapshot.recipient,
            role: .guest,
            authoritativeVersion: snapshot.authoritativeVersion,
            commitSequence: commitSequence,
            payload: .guest(.init(
                snapshot: snapshot,
                eventWindow: Array(eventWindow.suffix(128)),
                tokenReference: tokenReference,
                hostPlayerID: hostPlayerID
            ))
        )
    }

    static func host(
        protocolVersion: Int,
        rulesetVersion: String,
        recipientID: GameCore.PlayerID,
        state: GameCore.AuthoritativeGameState,
        gameState: GameCore.GameState,
        eventWindows: [GameCore.PlayerID: [SessionProtocol.SessionEnvelope]],
        tokenReferences: [RoomTokenReference],
        peersNeedingRecovery: Set<GameCore.PlayerID>,
        commitSequence: UInt64
    ) -> SessionArchive {
        let bounded = eventWindows.mapValues { Array($0.suffix(128)) }
        return SessionArchive(
            protocolVersion: protocolVersion,
            rulesetVersion: rulesetVersion,
            roomID: state.roomID,
            recipientID: recipientID,
            role: .host,
            authoritativeVersion: state.authoritativeVersion,
            commitSequence: commitSequence,
            payload: .host(.init(
                authoritativeState: .init(state),
                gameState: gameState,
                eventWindows: bounded,
                tokenReferences: tokenReferences,
                peersNeedingRecovery: peersNeedingRecovery
            ))
        )
    }
}

nonisolated struct SnapshotExpectation: Equatable, Sendable {
    let protocolVersion: Int
    let rulesetVersion: String
    let roomID: GameCore.RoomID
    let recipientID: GameCore.PlayerID
    let role: SessionArchiveRole
}

nonisolated enum SnapshotStoreError: Error, Equatable, Sendable {
    case missing
    case invalidKey
    case truncated
    case authenticationFailed
    case schemaMismatch
    case protocolMismatch
    case rulesetMismatch
    case roomMismatch
    case recipientMismatch
    case roleMismatch
    case versionMismatch
    case checksumMismatch
    case privacyViolation
    case invalidAuthorityState
    case incompleteAuthorityState
    case commitSequenceRollback
    case commitSequenceConflict
    case writeInterrupted
    case fileFailure
}

nonisolated struct SnapshotEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 4
    static let supportedSchemaVersions: Set<Int> = [2, currentSchemaVersion]

    var schemaVersion: Int
    let archive: SessionArchive
    var checksum: String

    init(archive: SessionArchive) throws {
        schemaVersion = Self.currentSchemaVersion
        self.archive = archive
        checksum = try Self.checksum(for: archive)
    }

    static func checksum(for archive: SessionArchive) throws -> String {
        try GameCore.CanonicalChecksum.sha256(archive)
    }
}

extension JSONEncoder {
    nonisolated static var canonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

nonisolated enum SnapshotCrypto {
    static func seal(_ plaintext: Data, keyData: Data) throws -> Data {
        guard keyData.count == 32 else { throw SnapshotStoreError.invalidKey }
        guard let combined = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData)).combined else {
            throw SnapshotStoreError.authenticationFailed
        }
        return combined
    }

    static func open(_ combined: Data, keyData: Data) throws -> Data {
        guard keyData.count == 32 else { throw SnapshotStoreError.invalidKey }
        guard combined.count >= 28 else { throw SnapshotStoreError.truncated }
        do {
            return try AES.GCM.open(
                AES.GCM.SealedBox(combined: combined),
                using: SymmetricKey(data: keyData)
            )
        } catch {
            throw SnapshotStoreError.authenticationFailed
        }
    }
}

nonisolated protocol SnapshotKeyProvider: Sendable {
    func keyData() throws -> Data
}

nonisolated struct KeychainSnapshotKeyProvider: SnapshotKeyProvider {
    static let service = "com.didi.prototype.IndustrialCityBirmingham.snapshot-key"
    static let account = "installation-key-v1"

    let adapter: any SecureItemAdapter

    init(adapter: some SecureItemAdapter = SecurityKeychainAdapter()) {
        self.adapter = adapter
    }

    func keyData() throws -> Data {
        if let existing = try adapter.read(service: Self.service, account: Self.account) {
            guard existing.count == 32 else { throw SnapshotStoreError.invalidKey }
            return existing
        }
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw SecureItemAdapterError.unavailable(status: status) }
        do {
            try adapter.add(key, service: Self.service, account: Self.account)
        } catch SecureItemAdapterError.duplicateItem {
            guard let raced = try adapter.read(service: Self.service, account: Self.account), raced.count == 32 else {
                throw SnapshotStoreError.invalidKey
            }
            return raced
        }
        return key
    }
}

nonisolated protocol SnapshotFileWriting: Sendable {
    func replaceCommittedFile(with data: Data, committedURL: URL, temporaryPrefix: String) throws
}

nonisolated struct AtomicSnapshotFileWriter: SnapshotFileWriting {
    func replaceCommittedFile(with data: Data, committedURL: URL, temporaryPrefix: String) throws {
        let directory = committedURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent("\(temporaryPrefix)\(UUID().uuidString)")
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw SnapshotStoreError.fileFailure
        }
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if fileManager.fileExists(atPath: committedURL.path) {
                _ = try fileManager.replaceItemAt(committedURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: committedURL)
            }
        } catch let error as SnapshotStoreError {
            throw error
        } catch {
            throw SnapshotStoreError.fileFailure
        }
    }
}

actor SnapshotStore {
    static let temporaryFilePrefix = ".industrial-city-session.tmp."

    nonisolated let committedFileURL: URL
    private let directory: URL
    private let keyProvider: any SnapshotKeyProvider
    private let fileWriter: any SnapshotFileWriting
    private let verifiedCatalog: GameCore.VerifiedGameDataCatalog?
    private var highestCommittedSequence: UInt64 = 0

    init(
        directory: URL,
        keyProvider: some SnapshotKeyProvider = KeychainSnapshotKeyProvider(),
        fileWriter: some SnapshotFileWriting = AtomicSnapshotFileWriter(),
        verifiedCatalog: GameCore.VerifiedGameDataCatalog? = nil
    ) {
        self.directory = directory
        self.keyProvider = keyProvider
        self.fileWriter = fileWriter
        self.verifiedCatalog = verifiedCatalog
        committedFileURL = directory.appendingPathComponent("industrial-city-session-v1.bin")
    }

    func save(_ archive: SessionArchive) throws {
        guard try validatePrivacy(archive) else { throw SnapshotStoreError.privacyViolation }
        try validateAuthorityState(in: archive)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: committedFileURL.path) {
            let committed = try decodeCommittedArchive()
            highestCommittedSequence = max(highestCommittedSequence, committed.commitSequence)
            if archive.commitSequence < committed.commitSequence {
                throw SnapshotStoreError.commitSequenceRollback
            }
            if archive.commitSequence == committed.commitSequence {
                guard try JSONEncoder.canonical.encode(archive) == JSONEncoder.canonical.encode(committed) else {
                    throw SnapshotStoreError.commitSequenceConflict
                }
                return
            }
        } else if archive.commitSequence < highestCommittedSequence {
            throw SnapshotStoreError.commitSequenceRollback
        }
        let envelope = try SnapshotEnvelope(archive: archive)
        let canonical = try JSONEncoder.canonical.encode(envelope)
        let encrypted = try SnapshotCrypto.seal(canonical, keyData: keyProvider.keyData())
        try fileWriter.replaceCommittedFile(
            with: encrypted,
            committedURL: committedFileURL,
            temporaryPrefix: Self.temporaryFilePrefix
        )
        highestCommittedSequence = archive.commitSequence
    }

    func load(
        expected: SnapshotExpectation,
        requiresCurrentSchema: Bool = false
    ) throws -> SessionArchive {
        guard FileManager.default.fileExists(atPath: committedFileURL.path) else {
            throw SnapshotStoreError.missing
        }
        let archive = try decodeCommittedArchive(requiresCurrentSchema: requiresCurrentSchema)
        guard archive.protocolVersion == expected.protocolVersion else { throw SnapshotStoreError.protocolMismatch }
        guard archive.rulesetVersion == expected.rulesetVersion else { throw SnapshotStoreError.rulesetMismatch }
        guard archive.roomID == expected.roomID else { throw SnapshotStoreError.roomMismatch }
        guard archive.recipientID == expected.recipientID else { throw SnapshotStoreError.recipientMismatch }
        guard archive.role == expected.role else { throw SnapshotStoreError.roleMismatch }
        guard archive.authoritativeVersion.rawValue >= 0 else { throw SnapshotStoreError.versionMismatch }
        try validateAuthorityState(in: archive)
        highestCommittedSequence = max(highestCommittedSequence, archive.commitSequence)
        return archive
    }

    private func decodeCommittedArchive(requiresCurrentSchema: Bool = false) throws -> SessionArchive {
        let encrypted: Data
        do { encrypted = try Data(contentsOf: committedFileURL) }
        catch { throw SnapshotStoreError.fileFailure }
        let plaintext = try SnapshotCrypto.open(encrypted, keyData: keyProvider.keyData())
        let envelope: SnapshotEnvelope
        do { envelope = try JSONDecoder().decode(SnapshotEnvelope.self, from: plaintext) }
        catch { throw SnapshotStoreError.truncated }
        guard SnapshotEnvelope.supportedSchemaVersions.contains(envelope.schemaVersion) else {
            throw SnapshotStoreError.schemaMismatch
        }
        guard !requiresCurrentSchema || envelope.schemaVersion == SnapshotEnvelope.currentSchemaVersion else {
            throw SnapshotStoreError.incompleteAuthorityState
        }
        let archive = envelope.archive
        guard envelope.checksum == (try SnapshotEnvelope.checksum(for: archive)) else {
            throw SnapshotStoreError.checksumMismatch
        }
        guard archive.authoritativeVersion.rawValue >= 0 else { throw SnapshotStoreError.versionMismatch }
        guard try validatePrivacy(
            archive,
            allowIncompleteHost: envelope.schemaVersion == 2
        ) else { throw SnapshotStoreError.privacyViolation }
        return archive
    }

    private func validateAuthorityState(in archive: SessionArchive) throws {
        guard let verifiedCatalog else { return }
        guard case .host(let host) = archive.payload,
              let gameState = host.gameState,
              GameCore.GameStateAuthorityValidator.isValid(gameState, catalog: verifiedCatalog)
        else {
            if archive.role == .host { throw SnapshotStoreError.invalidAuthorityState }
            return
        }
    }

    func cleanOrphanTemps() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for child in children where child.lastPathComponent.hasPrefix(Self.temporaryFilePrefix) {
            try FileManager.default.removeItem(at: child)
        }
    }

    func clearRecoveryMaterial() throws {
        if FileManager.default.fileExists(atPath: committedFileURL.path) {
            try FileManager.default.removeItem(at: committedFileURL)
        }
        try cleanOrphanTemps()
        highestCommittedSequence = 0
    }

    private func validatePrivacy(
        _ archive: SessionArchive,
        allowIncompleteHost: Bool = false
    ) throws -> Bool {
        switch archive.payload {
        case let .guest(guest):
            let rosterIDs = guest.snapshot.players.map(\.id)
            let roster = Set(rosterIDs)
            guard archive.role == .guest,
                  guest.snapshot.recipient == archive.recipientID,
                  guest.snapshot.roomID == archive.roomID,
                  guest.snapshot.authoritativeVersion == archive.authoritativeVersion,
                  guest.tokenReference.roomID == archive.roomID,
                  guest.tokenReference.playerID == archive.recipientID,
                  rosterIDs.count == roster.count,
                  roster.contains(guest.hostPlayerID),
                  guest.snapshot.players.allSatisfy({
                      $0.id == archive.recipientID ? $0.hand != nil : $0.hand == nil
                  }) else { return false }
            if archive.protocolVersion >= 2 {
                do {
                    try GameCore.RecipientSnapshotValidator.validate(
                        guest.snapshot,
                        context: .init(
                            protocolVersion: archive.protocolVersion,
                            rulesetVersion: archive.rulesetVersion,
                            roomID: archive.roomID,
                            recipient: archive.recipientID,
                            roster: roster,
                            authoritativeVersion: archive.authoritativeVersion
                        )
                    )
                } catch { return false }
            } else if guest.snapshot.checksum != (try GameCore.snapshotChecksum(
                roomID: guest.snapshot.roomID,
                recipient: guest.snapshot.recipient,
                players: guest.snapshot.players,
                activePlayerID: guest.snapshot.activePlayerID,
                turn: guest.snapshot.turn,
                actionNumber: guest.snapshot.actionNumber,
                authoritativeVersion: guest.snapshot.authoritativeVersion,
                discardPile: guest.snapshot.discardPile,
                forcedSale: guest.snapshot.forcedSale,
                match: guest.snapshot.match
            )) { return false }
            return validateWindow(
                guest.eventWindow,
                archive: archive,
                recipientID: archive.recipientID,
                hostID: guest.hostPlayerID,
                roster: roster
            )
        case let .host(host):
            guard allowIncompleteHost || host.gameState != nil else { return false }
            let rosterIDs = host.authoritativeState.players.map(\.id)
            let roster = Set(rosterIDs)
            let tokenIDs = host.tokenReferences.map(\.playerID)
            guard archive.role == .host,
                  host.authoritativeState.roomID == archive.roomID,
                  host.authoritativeState.authoritativeVersion == archive.authoritativeVersion,
                  rosterIDs.count == roster.count,
                  roster.contains(host.authoritativeState.activePlayerID),
                  host.tokenReferences.allSatisfy({ $0.roomID == archive.roomID }),
                  tokenIDs.count == Set(tokenIDs).count,
                  Set(tokenIDs) == roster,
                  host.peersNeedingRecovery.isSubset(of: roster) else { return false }
            if let gameState = host.gameState {
                guard gameState.rulesetVersion == archive.rulesetVersion,
                      gameState.authoritativeVersion == archive.authoritativeVersion,
                      gameState.players.map(\.id) == rosterIDs,
                      gameState.players.map({ $0.hand.map(\.id) }) == host.authoritativeState.players.map(\.hand),
                      gameState.activePlayerID == host.authoritativeState.activePlayerID,
                      gameState.roundNumber == host.authoritativeState.turn,
                      gameState.actionNumber == host.authoritativeState.actionNumber,
                      gameState.publicDiscard.map(\.id) == host.authoritativeState.discardPile else { return false }
            }
            return host.eventWindows.allSatisfy { recipientID, values in
                roster.contains(recipientID) && validateWindow(
                    values,
                    archive: archive,
                    recipientID: recipientID,
                    hostID: archive.recipientID,
                    roster: roster
                )
            }
        }
    }

    private func validateWindow(
        _ values: [SessionProtocol.SessionEnvelope],
        archive: SessionArchive,
        recipientID: GameCore.PlayerID,
        hostID: GameCore.PlayerID?,
        roster: Set<GameCore.PlayerID>?
    ) -> Bool {
        guard values.count <= 128 else { return false }
        var window = SessionProtocol.EventWindow(capacity: 128, expectedRoster: roster)
        for envelope in values {
            guard envelope.protocolVersion == archive.protocolVersion,
                  envelope.rulesetVersion == archive.rulesetVersion,
                  envelope.roomID == archive.roomID,
                  envelope.recipientID == recipientID,
                  hostID == nil || envelope.senderID == hostID,
                  case let .clientEvent(clientEvent) = envelope.payload,
                  roster == nil || roster!.contains(clientEvent.event.actor),
                  roster == nil || Set(clientEvent.snapshot.players.map(\.id)) == roster,
                  clientEvent.snapshot.players.contains(where: { $0.id == clientEvent.event.actor }) else {
                return false
            }
            do { try window.append(envelope) }
            catch { return false }
        }
        return values.last?.authoritativeVersion == nil
            || values.last?.authoritativeVersion == archive.authoritativeVersion
    }
}

nonisolated protocol SessionArchivePersisting: Sendable {
    func save(_ archive: SessionArchive) async throws
}

extension SnapshotStore: SessionArchivePersisting {}

nonisolated enum SessionPersistenceError: Error, Equatable, Sendable {
    case saveFailed
}

actor SessionRecoveryFailureTracker {
    private var counts: [RoomTokenReference: Int] = [:]

    func recordFailure(for reference: RoomTokenReference) -> Int {
        let count = counts[reference, default: 0] + 1
        counts[reference] = count
        return count
    }

    func reset(for reference: RoomTokenReference) {
        counts[reference] = nil
    }

    func failureCount(for reference: RoomTokenReference) -> Int {
        counts[reference, default: 0]
    }
}

nonisolated protocol GuestRecoveryFailureHandling: Sendable {
    func recordInvalidAuthenticatedMessage() async throws
    func recoverySucceeded() async
}

actor GuestRecoveryFailureHandler: GuestRecoveryFailureHandling {
    private let tracker: SessionRecoveryFailureTracker
    private let snapshotStore: SnapshotStore
    private let reference: RoomTokenReference

    init(
        tracker: SessionRecoveryFailureTracker,
        snapshotStore: SnapshotStore,
        reference: RoomTokenReference
    ) {
        self.tracker = tracker
        self.snapshotStore = snapshotStore
        self.reference = reference
    }

    func recordInvalidAuthenticatedMessage() async throws {
        let count = await tracker.recordFailure(for: reference)
        guard count >= 3 else { return }
        try await snapshotStore.clearRecoveryMaterial()
        throw RecoveryError.returnToLobby("recovery-material-invalid")
    }

    func recoverySucceeded() async {
        await tracker.reset(for: reference)
    }
}

nonisolated struct SessionPersistenceFactory: Sendable {
    let baseDirectory: URL
    let tokenStore: RoomTokenStore
    let keyProvider: any SnapshotKeyProvider
    private let failureTracker: SessionRecoveryFailureTracker
    var recoveryTrackerIdentity: ObjectIdentifier { ObjectIdentifier(failureTracker) }

    init(
        baseDirectory: URL = Self.defaultBaseDirectory,
        tokenStore: RoomTokenStore = RoomTokenStore(),
        keyProvider: some SnapshotKeyProvider = KeychainSnapshotKeyProvider(),
        failureTracker: SessionRecoveryFailureTracker = SessionRecoveryFailureTracker()
    ) {
        self.baseDirectory = baseDirectory
        self.tokenStore = tokenStore
        self.keyProvider = keyProvider
        self.failureTracker = failureTracker
    }

    static var nearbyRuntime: Self {
#if DEBUG && targetEnvironment(simulator)
        let adapter = DebugMemorySecureItemAdapter()
        return .init(
            tokenStore: RoomTokenStore(adapter: adapter),
            keyProvider: KeychainSnapshotKeyProvider(adapter: adapter)
        )
#else
        return .init()
#endif
    }

    func directory(roomID: GameCore.RoomID, playerID: GameCore.PlayerID) -> URL {
        let canonical = Data("\(roomID.rawValue)\u{001F}\(playerID.rawValue)".utf8)
        let identifier = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        return baseDirectory.appendingPathComponent(identifier, isDirectory: true)
    }

    func makeCoordinator(
        configuration proposed: SessionCoordinator.Configuration,
        role: SessionArchiveRole,
        transport: some Transport,
        rulesMode: SessionCoordinator.RulesMode
    ) async throws -> SessionCoordinator {
        let verifiedCatalog: GameCore.VerifiedGameDataCatalog?
        switch rulesMode {
        case .verified(let catalog): verifiedCatalog = catalog
#if DEBUG
        case .fixtureOnlyLegacy: verifiedCatalog = nil
#endif
        }
        let existing = try await tokenStore.load(roomID: proposed.roomID, playerID: proposed.playerID)
        let credential = existing ?? RoomTokenCredential(
            roomID: proposed.roomID,
            playerID: proposed.playerID,
            reconnectToken: proposed.reconnectToken
        )
        if existing == nil { try await tokenStore.save(credential) }
        let configuration = SessionCoordinator.Configuration(
            protocolVersion: proposed.protocolVersion,
            rulesetVersion: proposed.rulesetVersion,
            roomID: proposed.roomID,
            playerID: proposed.playerID,
            reconnectToken: credential.reconnectToken,
            hostPlayerID: proposed.hostPlayerID
        )
        let snapshotStore = SnapshotStore(
            directory: directory(roomID: configuration.roomID, playerID: configuration.playerID),
            keyProvider: keyProvider,
            verifiedCatalog: verifiedCatalog
        )
        let reference = RoomTokenReference(
            roomID: configuration.roomID,
            playerID: configuration.playerID
        )
        try await snapshotStore.cleanOrphanTemps()
        if role == .host {
            let expectation = SnapshotExpectation(
                protocolVersion: configuration.protocolVersion,
                rulesetVersion: configuration.rulesetVersion,
                roomID: configuration.roomID,
                recipientID: configuration.hostPlayerID,
                role: .host
            )
            do {
                let archive = try await snapshotStore.load(
                    expected: expectation,
                    requiresCurrentSchema: verifiedCatalog != nil
                )
                let recovery = RecoveryCoordinator(tokenStore: tokenStore)
                let restored: RestoredHostSession
                switch rulesMode {
                case .verified(let catalog):
                    restored = try await recovery.restoreHost(
                        archive: archive, expectedHostID: configuration.hostPlayerID, catalog: catalog
                    )
#if DEBUG
                case .fixtureOnlyLegacy:
                    restored = try await recovery.restoreFixtureOnlyHost(
                        archive: archive, expectedHostID: configuration.hostPlayerID
                    )
#endif
                }
                await failureTracker.reset(for: reference)
                return try SessionCoordinator(
                    configuration: configuration,
                    restored: restored,
                    transport: transport,
                    persistence: snapshotStore,
                    tokenStore: tokenStore,
                    rulesMode: rulesMode
                )
            } catch SnapshotStoreError.missing {
                // First launch of this room has no recovery material.
            } catch SnapshotStoreError.incompleteAuthorityState {
                // Verified play cannot resume from schema 2 because it lacks the
                // complete authority state. Preserve it for explicit migration.
            } catch SnapshotStoreError.protocolMismatch {
                // A valid archive from an older protocol is incompatible, not corrupt.
                // Preserve both archive and reconnect credential for explicit migration.
            } catch {
                try await handleInvalidRecoveryMaterial(
                    error,
                    reference: reference,
                    snapshotStore: snapshotStore
                )
            }
        } else {
            let guestFailureHandler = GuestRecoveryFailureHandler(
                tracker: failureTracker,
                snapshotStore: snapshotStore,
                reference: reference
            )
            let expectation = SnapshotExpectation(
                protocolVersion: configuration.protocolVersion,
                rulesetVersion: configuration.rulesetVersion,
                roomID: configuration.roomID,
                recipientID: configuration.playerID,
                role: .guest
            )
            do {
                let archive = try await snapshotStore.load(expected: expectation)
                guard case let .guest(restoredGuest) = archive.payload else {
                    throw SnapshotStoreError.roleMismatch
                }
                guard restoredGuest.hostPlayerID == configuration.hostPlayerID else {
                    throw SnapshotStoreError.privacyViolation
                }
                await failureTracker.reset(for: reference)
                return SessionCoordinator(
                    configuration: configuration,
                    restoredGuest: restoredGuest,
                    restoredCommitSequence: archive.commitSequence,
                    transport: transport,
                    persistence: snapshotStore,
                    tokenStore: tokenStore,
                    guestRecoveryFailureHandler: guestFailureHandler,
                    rulesMode: rulesMode
                )
            } catch SnapshotStoreError.missing {
                // This seat has not received a private projection yet.
            } catch SnapshotStoreError.protocolMismatch {
                // A valid archive from an older protocol is incompatible, not corrupt.
                // Preserve both archive and reconnect credential for explicit migration.
            } catch {
                try await handleInvalidRecoveryMaterial(
                    error,
                    reference: reference,
                    snapshotStore: snapshotStore
                )
            }
        }
        return SessionCoordinator(
            configuration: configuration,
            transport: transport,
            persistence: snapshotStore,
            tokenStore: tokenStore,
            guestRecoveryFailureHandler: role == .guest ? GuestRecoveryFailureHandler(
                tracker: failureTracker,
                snapshotStore: snapshotStore,
                reference: reference
            ) : nil,
            rulesMode: rulesMode
        )
    }

    func recoverableHostRooms(
        hostPlayerID: GameCore.PlayerID = .init(rawValue: "host"),
        catalog: GameCore.VerifiedGameDataCatalog
    ) async throws -> [RecoverableSessionReference] {
        try await recoverableHostRoomsValidated(hostPlayerID: hostPlayerID, catalog: catalog)
    }

#if DEBUG
    func recoverableFixtureOnlyHostRooms(
        hostPlayerID: GameCore.PlayerID = .init(rawValue: "host")
    ) async throws -> [RecoverableSessionReference] {
        try await recoverableHostRoomsValidated(hostPlayerID: hostPlayerID, catalog: nil)
    }
#endif

    private func recoverableHostRoomsValidated(
        hostPlayerID: GameCore.PlayerID,
        catalog: GameCore.VerifiedGameDataCatalog?
    ) async throws -> [RecoverableSessionReference] {
        let expectedRulesetVersion = catalog?.catalog.rulesetVersion ?? "rules-v1"
        let references = try await tokenStore.references(playerID: hostPlayerID)
        var recoverable: [RecoverableSessionReference] = []
        for reference in references {
            let store = SnapshotStore(
                directory: directory(roomID: reference.roomID, playerID: reference.playerID),
                keyProvider: keyProvider,
                verifiedCatalog: catalog
            )
            do {
                let expectedProtocol = catalog == nil ? 1 : 2
                let archive = try await store.load(
                    expected: .init(
                        protocolVersion: expectedProtocol,
                        rulesetVersion: expectedRulesetVersion,
                        roomID: reference.roomID,
                        recipientID: hostPlayerID,
                        role: .host
                    ),
                    requiresCurrentSchema: true
                )
                let recovery = RecoveryCoordinator(tokenStore: tokenStore)
                if let catalog {
                    _ = try await recovery.restoreHost(
                        archive: archive, expectedHostID: hostPlayerID, catalog: catalog
                    )
                }
#if DEBUG
                if catalog == nil {
                    _ = try await recovery.restoreFixtureOnlyHost(
                        archive: archive, expectedHostID: hostPlayerID
                    )
                }
#endif
                await failureTracker.reset(for: reference)
                recoverable.append(.init(
                    roomID: reference.roomID,
                    playerID: reference.playerID,
                    role: .host,
                    rulesetVersion: archive.rulesetVersion
                ))
            } catch SnapshotStoreError.missing {
                continue
            } catch SnapshotStoreError.rulesetMismatch {
                // A valid save for another ruleset is incompatible, not corrupt.
                // Keep it intact so a matching app/ruleset can recover it later.
                continue
            } catch SnapshotStoreError.protocolMismatch {
                // A valid archive for an older protocol is incompatible, not corrupt.
                // Keep its archive and reconnect credential intact for explicit migration.
                continue
            } catch SnapshotStoreError.incompleteAuthorityState {
                // Schema 2 intentionally lacks the complete GameState required
                // for continuing authoritative play. Keep it for explicit legacy migration.
                continue
            } catch {
                let count = await failureTracker.recordFailure(for: reference)
                if count >= 3 {
                    try await store.clearRecoveryMaterial()
                    throw RecoveryError.returnToLobby("recovery-material-invalid")
                }
            }
        }
        return recoverable
    }

    private func handleInvalidRecoveryMaterial(
        _ error: any Error,
        reference: RoomTokenReference,
        snapshotStore: SnapshotStore
    ) async throws -> Never {
        let count = await failureTracker.recordFailure(for: reference)
        guard count >= 3 else { throw error }
        try await snapshotStore.clearRecoveryMaterial()
        throw RecoveryError.returnToLobby("recovery-material-invalid")
    }

    private static var defaultBaseDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("IndustrialCityBirmingham/Sessions", isDirectory: true)
    }
}
