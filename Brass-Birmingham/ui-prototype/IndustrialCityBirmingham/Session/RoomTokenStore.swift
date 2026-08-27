import Foundation
import Security

nonisolated struct RoomTokenCredential: Codable, Equatable, Sendable {
    let roomID: GameCore.RoomID
    let playerID: GameCore.PlayerID
    let reconnectToken: GameCore.ReconnectToken
}

nonisolated enum SecureItemAdapterError: Error, Equatable, Sendable {
    case duplicateItem
    case itemNotFound
    case unexpectedData
    case unavailable(status: OSStatus)
}

nonisolated protocol SecureItemAdapter: Sendable {
    func read(service: String, account: String) throws -> Data?
    func readAll(service: String) throws -> [Data]
    func add(_ data: Data, service: String, account: String) throws
    func update(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

nonisolated struct SecurityKeychainAdapter: SecureItemAdapter {
    func read(service: String, account: String) throws -> Data? {
        var result: CFTypeRef?
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw map(status) }
        guard let data = result as? Data else { throw SecureItemAdapterError.unexpectedData }
        return data
    }

    func add(_ data: Data, service: String, account: String) throws {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw map(status) }
    }

    func readAll(service: String) throws -> [Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw map(status) }
        guard let items = result as? [[String: Any]] else {
            throw SecureItemAdapterError.unexpectedData
        }
        return try items.map { item in
            guard let data = item[kSecValueData as String] as? Data else {
                throw SecureItemAdapterError.unexpectedData
            }
            return data
        }
    }

    func update(_ data: Data, service: String, account: String) throws {
        let status = SecItemUpdate(
            baseQuery(service: service, account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecSuccess else { throw map(status) }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw map(status) }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func map(_ status: OSStatus) -> SecureItemAdapterError {
        switch status {
        case errSecDuplicateItem: .duplicateItem
        case errSecItemNotFound: .itemNotFound
        default: .unavailable(status: status)
        }
    }
}

#if DEBUG
nonisolated final class DebugMemorySecureItemAdapter: SecureItemAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func read(service: String, account: String) throws -> Data? {
        lock.withLock { storage[key(service: service, account: account)] }
    }

    func readAll(service: String) throws -> [Data] {
        lock.withLock {
            let prefix = "\(service)|"
            return storage.compactMap { key, value in key.hasPrefix(prefix) ? value : nil }
        }
    }

    func add(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            let itemKey = key(service: service, account: account)
            guard storage[itemKey] == nil else { throw SecureItemAdapterError.duplicateItem }
            storage[itemKey] = data
        }
    }

    func update(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            let itemKey = key(service: service, account: account)
            guard storage[itemKey] != nil else { throw SecureItemAdapterError.itemNotFound }
            storage[itemKey] = data
        }
    }

    func delete(service: String, account: String) throws {
        lock.withLock { storage[key(service: service, account: account)] = nil }
    }

    private func key(service: String, account: String) -> String { "\(service)|\(account)" }
}
#endif

actor RoomTokenStore {
    static let service = "com.didi.prototype.IndustrialCityBirmingham.room-token"

    private let adapter: any SecureItemAdapter
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(adapter: some SecureItemAdapter = SecurityKeychainAdapter()) {
        self.adapter = adapter
    }

    func save(_ credential: RoomTokenCredential) throws {
        let account = account(roomID: credential.roomID, playerID: credential.playerID)
        let encoded = try encoder.encode(credential)
        if try adapter.read(service: Self.service, account: account) == nil {
            do {
                try adapter.add(encoded, service: Self.service, account: account)
            } catch SecureItemAdapterError.duplicateItem {
                try adapter.update(encoded, service: Self.service, account: account)
            }
        } else {
            try adapter.update(encoded, service: Self.service, account: account)
        }
    }

    func load(roomID: GameCore.RoomID, playerID: GameCore.PlayerID) throws -> RoomTokenCredential? {
        guard let encoded = try adapter.read(
            service: Self.service,
            account: account(roomID: roomID, playerID: playerID)
        ) else { return nil }
        let credential = try decoder.decode(RoomTokenCredential.self, from: encoded)
        guard credential.roomID == roomID, credential.playerID == playerID else {
            throw SecureItemAdapterError.unexpectedData
        }
        return credential
    }

    func delete(roomID: GameCore.RoomID, playerID: GameCore.PlayerID) throws {
        try adapter.delete(
            service: Self.service,
            account: account(roomID: roomID, playerID: playerID)
        )
    }

    func references(playerID: GameCore.PlayerID) throws -> [RoomTokenReference] {
        let references = try adapter.readAll(service: Self.service).map { encoded in
            let credential = try decoder.decode(RoomTokenCredential.self, from: encoded)
            return RoomTokenReference(roomID: credential.roomID, playerID: credential.playerID)
        }
        return Array(Set(references.filter { $0.playerID == playerID })).sorted {
            if $0.roomID.rawValue == $1.roomID.rawValue {
                return $0.playerID.rawValue < $1.playerID.rawValue
            }
            return $0.roomID.rawValue < $1.roomID.rawValue
        }
    }

    private func account(roomID: GameCore.RoomID, playerID: GameCore.PlayerID) -> String {
        "room:\(roomID.rawValue)|player:\(playerID.rawValue)"
    }
}
