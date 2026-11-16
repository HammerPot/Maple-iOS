import Foundation
import Security
import OSLog
import BetterAuth

/// CookieStorage calls this from its locked, synchronous persistence boundary.
struct MapleKeychainStorage: StorageProtocol {
    private let logger = Logger(subsystem: "dev.hammerpot.Maple-iOS", category: "SessionKeychain")
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.hammerpot.Maple-iOS.session",
         kSecAttrAccount as String: key]
    }
    func get(key: String) -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            logger.error("Session Keychain read failed: \(status)")
            return nil
        }
        guard let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func save(key: String, value: String) throws -> Bool {
        let query = query(key)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
        guard status == errSecSuccess else {
            // Do not delete an existing item on errSecInteractionNotAllowed; retry when unlocked.
            throw MapleError(status: 0, code: "KEYCHAIN_\(status)", message: "Your session could not be saved securely. Unlock your device and try again.")
        }
        return true
    }
}
