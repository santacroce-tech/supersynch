import Foundation
import Security

/// Storage for API keys. Production uses the Keychain; tests use memory.
public protocol SecretStore: Sendable {
    func secret(for account: String) throws -> String?
    func setSecret(_ secret: String, for account: String) throws
    func removeSecret(for account: String) throws
}

public enum SecretStoreError: Error, LocalizedError, Equatable {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            return String(localized: "Keychain error: \(message)", bundle: SyncthingKit.bundle)
        }
    }
}

/// Generic-password Keychain items, readable after first unlock on this device
/// only (not synced, not included in unencrypted backups).
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "xyz.santacroce.SuperSynch.apikey") {
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
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    public func setSecret(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add.merge(attributes) { $1 }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecretStoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw SecretStoreError.keychain(status)
        }
    }

    public func removeSecret(for account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status)
        }
    }
}

/// In-memory store for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func secret(for account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[account]
    }

    public func setSecret(_ secret: String, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = secret
    }

    public func removeSecret(for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = nil
    }
}
