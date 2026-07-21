import Foundation
import Security

/// Generic Keychain-backed secret storage. The ElevenLabs API key never
/// touches SFConfig's plaintext JSON — only non-secret settings (voice ID,
/// model ID, enabled flag) live there. Behind a protocol so callers can be
/// tested with a fake rather than exercising the real Keychain.
public protocol CredentialStoring: Sendable {
    func save(_ value: String) throws
    func load() -> String?
    func delete() throws
}

public enum CredentialStoreError: Error, Sendable {
    case encodingFailed
    case keychainError(OSStatus)
}

public struct KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ value: String) throws {
        guard let data = value.data(using: .utf8) else { throw CredentialStoreError.encodingFailed }

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            // Not synced to iCloud Keychain, only readable while the
            // device is unlocked — a reasonable default for a local secret.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.keychainError(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw CredentialStoreError.keychainError(updateStatus)
        }
    }

    public func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainError(status)
        }
    }
}

/// Convenience namespace for the single ElevenLabs API-key secret.
public enum ElevenLabsCredentialStore {
    /// Keychain service the API key is stored under. Override once at launch to
    /// brand it for your app (e.g. `"com.example.app.elevenlabs"`); defaults to
    /// a neutral value so the package carries no app identity of its own.
    public nonisolated(unsafe) static var service = "swift.elevenlabs"

    private static var store: KeychainCredentialStore {
        KeychainCredentialStore(service: service, account: "api-key")
    }

    public static func save(_ apiKey: String) throws { try store.save(apiKey) }
    public static func load() -> String? { store.load() }
    public static func delete() throws { try store.delete() }
}
