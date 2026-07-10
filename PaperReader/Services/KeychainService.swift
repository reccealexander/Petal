import Foundation
import Security

/// Stores and retrieves the user's Google AI Studio API key in the macOS
/// Keychain. Never persists the key in UserDefaults or plaintext on disk
/// (spec §5).
public final class KeychainService: @unchecked Sendable {
    private static let service = "com.paperreader.googleaistudio"
    private static let account = "api-key"

    public init() {}

    /// Thrown when a Keychain operation fails with a non-`errSecSuccess` status.
    public enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    /// Stores `key`, replacing any existing stored value.
    public func setAPIKey(_ key: String) throws {
        // Remove any existing item first so re-saving doesn't collide with
        // an existing entry for the same service/account.
        deleteAPIKey()

        guard let data = key.data(using: .utf8) else {
            throw KeychainError.unexpectedStatus(errSecParam)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: data,
            // Stable, non-UI-gated accessibility class: the item is usable
            // as soon as the device has been unlocked once after boot, and
            // isn't tied to any biometric/passcode prompt policy. Doesn't
            // affect the per-app "Always Allow" ACL prompt, but keeps
            // accessibility semantics well-defined and predictable.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Returns the stored API key, or `nil` if none has been set.
    public func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the stored API key, if any. A missing item is not an error.
    public func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound just means there was nothing to delete.
        _ = status
    }

    /// Convenience check for whether an API key is currently stored.
    public var hasAPIKey: Bool {
        apiKey() != nil
    }
}
