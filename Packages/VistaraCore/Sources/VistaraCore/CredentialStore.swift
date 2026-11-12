import Foundation
import Security

/// A user name and password as kept for one connection.
///
/// Printing or dumping a value never shows the password, so it cannot reach
/// a log or a crash report that way.
public struct StoredCredentials: Equatable, Sendable {
    public var username: String
    public var domain: String?
    public var password: String

    public init(username: String, domain: String? = nil, password: String) {
        self.username = username
        self.domain = domain
        self.password = password
    }

    /// "DOMAIN\user", or the user name alone.
    public var account: String {
        guard let domain, !domain.isEmpty else { return username }
        return "\(domain)\\\(username)"
    }

    /// The reverse of `account`.
    public static func split(account: String) -> (username: String, domain: String?) {
        let parts = account.split(separator: "\\", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return (account, nil) }
        return (String(parts[1]), String(parts[0]))
    }
}

extension StoredCredentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "StoredCredentials(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Where passwords live. The only implementation that keeps anything beyond
/// the life of the process is the Keychain.
///
/// `key` identifies the connection: a connection's `id`, or the address of a
/// computer that has no saved connection.
public protocol CredentialStore: Sendable {
    func credentials(for key: String) throws -> StoredCredentials?
    /// Saves or replaces. `label` is the name the item has in Keychain Access.
    func save(_ credentials: StoredCredentials, for key: String, label: String) throws
    /// Removes the item. Does nothing if there is none.
    func remove(for key: String) throws
}

public struct CredentialStoreError: Error, Equatable, CustomStringConvertible {
    /// The Security framework's result code.
    public var status: OSStatus

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Passwords in the user's keychain, one generic password item per
/// connection. The item's account is the user name, so Keychain Access shows
/// it like any other password. Items are not synchronized to iCloud.
public struct KeychainCredentialStore: CredentialStore {
    public static let defaultServicePrefix = "io.github.sysmike.vistara.connection."

    private let servicePrefix: String

    public init(servicePrefix: String = KeychainCredentialStore.defaultServicePrefix) {
        self.servicePrefix = servicePrefix
    }

    private func baseQuery(for key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: servicePrefix + key]
    }

    public func credentials(for key: String) throws -> StoredCredentials? {
        var query = baseQuery(for: key)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnAttributes] = true
        query[kSecReturnData] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
        guard let item = result as? [CFString: Any], let data = item[kSecValueData] as? Data,
            let password = String(data: data, encoding: .utf8)
        else { return nil }

        let account = StoredCredentials.split(account: item[kSecAttrAccount] as? String ?? "")
        return StoredCredentials(username: account.username, domain: account.domain, password: password)
    }

    public func save(_ credentials: StoredCredentials, for key: String, label: String) throws {
        try remove(for: key)
        var item = baseQuery(for: key)
        item[kSecAttrAccount] = credentials.account
        item[kSecAttrLabel] = label
        item[kSecValueData] = Data(credentials.password.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
    }

    public func remove(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError(status: status)
        }
    }
}

/// Keeps credentials for the life of the process only. For tests and previews.
public final class InMemoryCredentialStore: CredentialStore {
    private let items = NSLock()
    private nonisolated(unsafe) var storage: [String: StoredCredentials] = [:]

    public init() {}

    public func credentials(for key: String) throws -> StoredCredentials? {
        items.withLock { storage[key] }
    }

    public func save(_ credentials: StoredCredentials, for key: String, label: String) throws {
        items.withLock { storage[key] = credentials }
    }

    public func remove(for key: String) throws {
        items.withLock { storage[key] = nil }
    }
}
