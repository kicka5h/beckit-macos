import Foundation
import Security

/// Stores the GitHub token in the login keychain.
///
/// Beckit 3.x wrote the token in cleartext to
/// `~/Library/Application Support/beckit/config.json`, where any process
/// running as the user — and every Time Machine and cloud backup — could read
/// it. The keychain gives it file protection, per-app ACLs, and removal when
/// the user signs out.
public struct TokenStore: Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.beckit.github", account: String = "oauth-token") {
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

    public func save(_ token: String) throws {
        let data = Data(token.utf8)

        // Try to update first; SecItemAdd fails outright on a duplicate.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TokenStoreError.keychain(updateStatus)
        }

        var query = baseQuery
        query[kSecValueData as String] = data
        // The token is only needed while the writer is using their Mac, and
        // should never sync to another device.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw TokenStoreError.keychain(addStatus) }
    }

    public func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw TokenStoreError.keychain(status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychain(status)
        }
    }
}

public enum TokenStoreError: Error, LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error: \(detail ?? "status \(status)")"
        }
    }
}
