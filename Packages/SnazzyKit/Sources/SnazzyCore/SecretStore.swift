import Foundation
import Security

/// Storage for API keys. The only production implementation is the Keychain;
/// secrets are never written to files, UserDefaults or logs.
public protocol SecretStore: Sendable {
    func secret(for account: String) throws -> String?
    func setSecret(_ value: String, for account: String) throws
    func deleteSecret(for account: String) throws
}

public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus
    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Generic-password items in the login Keychain, one per provider account.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "com.snazzy.pro.api-keys") {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func secret(for account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func setSecret(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Snazzy Pro: \(account) API key"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        Log.keychain.info("Stored secret for account \(account, privacy: .public)")
    }

    public func deleteSecret(for account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        Log.keychain.info("Deleted secret for account \(account, privacy: .public)")
    }
}

/// For tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init(_ initial: [String: String] = [:]) { values = initial }

    public func secret(for account: String) throws -> String? { lock.withLock { values[account] } }
    public func setSecret(_ value: String, for account: String) throws { lock.withLock { values[account] = value } }
    public func deleteSecret(for account: String) throws { lock.withLock { _ = values.removeValue(forKey: account) } }
}
