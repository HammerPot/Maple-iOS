import Foundation
import Testing
@testable import Maple

actor SettingsFakeCredentials: WebhookCredentialStoring {
    var value: String
    var fails: Bool
    init(_ value: String = "", fails: Bool = false) { self.value = value; self.fails = fails }
    func read() -> String { value }
    func write(_ value: String) throws {
        if fails { throw CocoaError(.fileWriteNoPermission) }
        self.value = value
    }
}
@MainActor struct SettingsTests {
    @Test func migratesLegacyOnceAndPrefersExistingSecureValue() async throws {
        let suite = "SettingsTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = "https://discord.com/api/webhooks/123/test-token"
        defaults.set(legacy, forKey: "webhookURL")
        let credentials = SettingsFakeCredentials()
        let model = SettingsModel(credentials: credentials, defaults: defaults)
        try await model.load()
        #expect(await credentials.read() == legacy)
        #expect(defaults.object(forKey: "webhookURL") == nil)
        defaults.set("stale", forKey: "webhookURL")
        let next = SettingsModel(credentials: credentials, defaults: defaults)
        try await next.load(); #expect(next.webhookURL == legacy)
        #expect(defaults.object(forKey: "webhookURL") == nil)
    }
    @Test func failedMigrationRetainsOnlyRecoverableLegacyCopy() async throws {
        let suite = "SettingsTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-secret", forKey: "webhookURL")
        let model = SettingsModel(credentials: SettingsFakeCredentials(fails: true), defaults: defaults)
        await #expect(throws: CocoaError.self) { try await model.load() }
        #expect(defaults.string(forKey: "webhookURL") == "legacy-secret")
        #expect(!model.isLoaded)
    }
    @Test(arguments: ["http://discord.com/api/webhooks/123/token", "https://discord.com.evil.test/api/webhooks/123/token", "https://user@discord.com/api/webhooks/123/token", "https://discord.com/channels/123/456", "https://discord.com/api/webhooks/123/", "https://discord.com/api/webhooks/123/../token", "https://discord.com/api/webhooks/123/a%2Fb"])
    func rejectsNonWebhookAndSpoofedHosts(_ value: String) { #expect(!DiscordWebhookURL.isValid(value)) }
    @Test func acceptsDiscordWebhookAndCanRemoveCredential() async throws {
        let value = "https://discord.com/api/webhooks/123/test_TOKEN-1"
        #expect(DiscordWebhookURL.isValid(value))
        let credentials = SettingsFakeCredentials(value)
        let suite = "SettingsTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsModel(credentials: credentials, defaults: defaults)
        try await model.load(); model.webhookURL = ""; try await model.saveWebhook()
        #expect(await credentials.read().isEmpty)
    }
}

extension SettingsTests {
    @Test func acceptsVersionedAndTrailingSlashDiscordWebhooks() {
        #expect(DiscordWebhookURL.isValid("https://discord.com/api/v10/webhooks/123/test-token/"))
        #expect(DiscordWebhookURL.isValid("https://discord.com/api/webhooks/123/test-token/"))
    }
}

extension SettingsTests {
    @Test func unsupportedLegacyWebhookStaysRecoverableAndIsFlaggedInSettings() async throws {
        let suite = "SettingsTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = "https://relay.example.test/existing-hook"
        defaults.set(old, forKey: "webhookURL")
        let credentials = SettingsFakeCredentials(), model = SettingsModel(credentials: credentials, defaults: defaults)
        try await model.load()
        #expect(model.webhookURL == old); #expect(await credentials.read() == old)
        #expect(model.webhookValidationMessage != nil)
        model.webhookURL = ""; try await model.saveWebhook()
        #expect(model.webhookValidationMessage == nil); #expect(await credentials.read().isEmpty)
    }
}
