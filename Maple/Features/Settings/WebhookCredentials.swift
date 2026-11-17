import Foundation
import Security

protocol WebhookCredentialStoring: Sendable {
    func read() async throws -> String
    func write(_ value: String) async throws
}

/// Independent service: clearing account cookies never removes the user's opt-in webhook.
actor WebhookCredentials: WebhookCredentialStoring {
    private let service = "dev.hammerpot.Maple-iOS.webhook"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "discord-webhook"]
    }
    func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw WebhookCredentialError(status: status)
        }
        return value
    }
    func write(_ value: String) throws {
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw WebhookCredentialError(status: status) }
            return
        }
        var request = query
        request[kSecValueData as String] = Data(value.utf8)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(request as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        }
        guard status == errSecSuccess else { throw WebhookCredentialError(status: status) }
    }
}
struct WebhookCredentialError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "The webhook could not be saved securely (\(status)). Try again after unlocking your device." }
}

enum DiscordWebhookURL {
    static func isValid(_ value: String) -> Bool {
        guard let url = URLComponents(string: value), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil,
              let host = url.host?.lowercased(), ["discord.com", "discordapp.com", "canary.discord.com", "ptb.discord.com"].contains(host) else { return false }
        var parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        if parts.count == 6, parts[2].first == "v", !parts[2].dropFirst().isEmpty,
           parts[2].dropFirst().allSatisfy(\.isNumber) { parts.remove(at: 2) }
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "api", parts[2] == "webhooks",
              !parts[3].isEmpty, parts[3].allSatisfy(\.isNumber), !parts[4].isEmpty else { return false }
        return parts[4].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
