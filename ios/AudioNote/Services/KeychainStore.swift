import Foundation
import Security

/// Thin wrapper around the iOS Keychain for storing short opaque secrets
/// keyed by an account string. All entries live under `service = "audioNote.llm"`
/// with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which keeps the
/// secret out of iCloud backups and unavailable until the user has unlocked
/// the device at least once after boot.
///
/// Currently used by `ProviderProfileStore` to persist per-profile API keys.
/// Read/write failures surface as `KeychainError` so callers can react
/// (e.g. surface a toast in Settings) instead of silently dropping the value.
///
/// See `docs/superpowers/specs/2026-09-24-multi-provider-llm-design.md`.
enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case encodingFailed
    case notFound

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        case .encodingFailed:
            return "Keychain error: failed to encode value."
        case .notFound:
            return "Keychain error: item not found."
        }
    }
}

struct KeychainStore {
    static let shared = KeychainStore(service: "audioNote.llm")

    let service: String

    init(service: String) {
        self.service = service
    }

    // MARK: - Set / Update

    /// Upsert a UTF-8 string under `account`. Throws on encoding or status
    /// failure; never silently drops.
    func set(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    // MARK: - Get

    /// Returns the stored string for `account`, or nil if no entry exists.
    /// Throws only on Keychain infrastructure errors (status != success / notFound).
    func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.encodingFailed
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Delete

    /// Removes the entry. `errSecItemNotFound` is treated as success — the
    /// post-condition (no entry) is satisfied either way.
    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
