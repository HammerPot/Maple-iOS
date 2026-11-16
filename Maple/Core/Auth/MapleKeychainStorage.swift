import Foundation
import Security
import OSLog
import BetterAuth

/// CookieStorage calls this from its locked, synchronous persistence boundary.
struct MapleKeychainStorage: StorageProtocol {
    static let defaultService = "dev.hammerpot.Maple-iOS.session"
    static let installMarker = "maple.keychain.installMarker"
    private let onSaveFailure: @Sendable (MapleError) -> Void
    private let addItem: ([String: Any]) -> OSStatus
    private let updateItem: ([String: Any], [String: Any]) -> OSStatus
    private let logger = Logger(subsystem: "dev.hammerpot.Maple-iOS", category: "SessionKeychain")
    let service: String
    init(service: String = MapleKeychainStorage.defaultService,
         onSaveFailure: @escaping @Sendable (MapleError) -> Void = { _ in },
         addItem: @escaping ([String: Any]) -> OSStatus = { SecItemAdd($0 as CFDictionary, nil) },
         updateItem: @escaping ([String: Any], [String: Any]) -> OSStatus = { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) }) {
        self.service = service; self.onSaveFailure = onSaveFailure
        self.addItem = addItem; self.updateItem = updateItem
    }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
    /// Keychain items survive app deletion. On the first launch of a fresh install (no UserDefaults marker,
    /// which does not survive deletion) remove anything left over. Returns true if a wipe happened.
    @discardableResult
    static func wipeIfFreshInstall(defaults: UserDefaults, service: String = defaultService) -> Bool {
        guard !defaults.bool(forKey: installMarker) else { return false }
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return false }
        defaults.set(true, forKey: installMarker)
        return true
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
        var status = addItem(item)
        if status == errSecDuplicateItem { status = updateItem(query, attributes) }
        guard status == errSecSuccess else {
            // Do not delete an existing item on errSecInteractionNotAllowed; retry when unlocked.
            logger.error("Session Keychain write failed: \(status)")
            let error = MapleError(status: 0, code: "KEYCHAIN_\(status)", message: "Your session could not be saved securely. You may be signed out when the app restarts.")
            onSaveFailure(error)
            throw error
        }
        return true
    }
}
