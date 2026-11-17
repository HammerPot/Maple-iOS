import Foundation
import Observation

@MainActor @Observable final class SettingsModel {
    var webhookURL = ""
    var webhookValidationMessage: String? {
        let value = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !DiscordWebhookURL.isValid(value) else { return nil }
        return "This saved webhook is not a supported Discord URL. Delivery is disabled. Replace it with a Discord webhook URL or clear it."
    }
    private(set) var isSaving = false
    private(set) var isLoaded = false
    @ObservationIgnored private let credentials: any WebhookCredentialStoring
    @ObservationIgnored private let defaults: UserDefaults
    init(credentials: any WebhookCredentialStoring, defaults: UserDefaults = .standard) {
        self.credentials = credentials; self.defaults = defaults
    }
    func load() async throws {
        guard !isLoaded else { return }
        let secure = try await credentials.read()
        if let rawLegacy = defaults.string(forKey: "webhookURL") {
            let legacy = rawLegacy.trimmingCharacters(in: .whitespacesAndNewlines)
            // Never remove the legacy copy before a durable Keychain write succeeds.
            if secure.isEmpty, !legacy.isEmpty {
                try await credentials.write(legacy)
                guard try await credentials.read() == legacy else { throw WebhookCredentialError(status: -50) }
            }
            defaults.removeObject(forKey: "webhookURL")
            webhookURL = secure.isEmpty ? legacy : secure
        } else { webhookURL = secure }
        isLoaded = true
    }
    func saveWebhook() async throws {
        let value = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || DiscordWebhookURL.isValid(value) else {
            throw MapleError(status: 0, message: "Enter a Discord webhook URL beginning with https://discord.com/api/webhooks/.")
        }
        isSaving = true
        defer { isSaving = false }
        try await credentials.write(value)
        defaults.removeObject(forKey: "webhookURL")
        webhookURL = value
    }
}
