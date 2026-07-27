import Foundation
import Security

/// Thin Keychain wrapper for storing the host's ed25519 private key and
/// the list of paired device public keys. Uses the Keychain generic-password
/// class so the data stays under the user's login keychain.
public enum Keychain {
    public enum KeychainError: Error, CustomStringConvertible {
        case status(OSStatus)
        case decode
        case notFound

        public var description: String {
            switch self {
            case .status(let s): return "Keychain OSStatus=\(s)"
            case .decode: return "Keychain decode failure"
            case .notFound: return "Keychain item not found"
            }
        }
    }

    public static let service = "io.glasstunnel.host"

    public static func store(_ data: Data, forAccount account: String) throws {
        try delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func load(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = result as? Data else { throw KeychainError.decode }
        return data
    }

    public static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess { return }
        throw KeychainError.status(status)
    }
}
