import Foundation
#if canImport(Security)
import Security
#endif

public protocol SensitiveCredentialStore: Sendable {
    func get(service: String, account: String) async throws -> Data?
    func set(_ data: Data, service: String, account: String) async throws
    func remove(service: String, account: String) async throws
}

public actor InMemoryCredentialStore: SensitiveCredentialStore {
    private var values: [String: Data] = [:]
    public init() {}

    public func get(service: String, account: String) -> Data? { values[key(service, account)] }
    public func set(_ data: Data, service: String, account: String) { values[key(service, account)] = data }
    public func remove(service: String, account: String) { values.removeValue(forKey: key(service, account)) }
    private func key(_ service: String, _ account: String) -> String { service + "\u{0}" + account }
}

public struct CredentialStoreError: Error, Sendable, Equatable {
    public let operation: String
    public let status: Int32
    public init(operation: String, status: Int32) { self.operation = operation; self.status = status }
}

#if canImport(Security)
public final class KeychainCredentialStore: SensitiveCredentialStore, @unchecked Sendable {
    public static let servicePrefix = "ivlyrics.credentials.v1"
    public init() {}

    public func get(service: String, account: String) async throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError(operation: "read", status: status) }
        guard let data = result as? Data else { throw CredentialStoreError(operation: "read", status: errSecDecode) }
        return data
    }

    public func set(_ data: Data, service: String, account: String) async throws {
        let query = baseQuery(service: service, account: account)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError(operation: "write", status: updateStatus)
        }
        var insert = query
        insert.merge(update) { _, new in new }
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError(operation: "write", status: status) }
    }

    public func remove(service: String, account: String) async throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError(operation: "delete", status: status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.servicePrefix + "." + service,
         kSecAttrAccount as String: account]
    }
}
#endif
