import Foundation
import Observation

@MainActor @Observable
final class PasskeysModel {
    private(set) var items: [PasskeyItem] = []
    private(set) var hasLoaded = false
    private(set) var isBusy = false
    var errorMessage: String?
    private(set) var statusMessage: String?
    @ObservationIgnored private let service: any PasskeyService

    init(service: any PasskeyService) { self.service = service }

    func load() async {
        do { items = try await service.passkeys().sorted { $0.createdAt > $1.createdAt }; hasLoaded = true; errorMessage = nil }
        catch { await fail(error, purpose: nil) }
    }

    func add() async {
        guard PasskeySupport.isEnabled, !isBusy else { return }
        isBusy = true; statusMessage = nil; defer { isBusy = false }
        do {
            try await service.registerPasskey(name: nil)
            statusMessage = "Passkey added."
            await load()
        } catch { await fail(error, purpose: .register) }
    }

    func rename(_ item: PasskeyItem, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        isBusy = true; defer { isBusy = false }
        do { try await service.renamePasskey(id: item.id, name: String(trimmed.prefix(64))); await load() }
        catch { await fail(error, purpose: nil) }
    }

    func delete(_ item: PasskeyItem) async {
        isBusy = true; statusMessage = nil; defer { isBusy = false }
        do {
            try await service.deletePasskey(id: item.id)
            items.removeAll { $0.id == item.id }
            statusMessage = "Passkey removed."
        } catch { await fail(error, purpose: nil) }
    }

    private func fail(_ error: Error, purpose: PasskeySupport.Purpose?) async {
        if AccountErrorCopy.endsSession(error) { await service.invalidate(); return }
        errorMessage = purpose.map { PasskeySupport.message(for: error, purpose: $0) } ?? AccountErrorCopy.message(for: error)
    }
}

/// The web client's one-time "Add a passkey?" nudge, remembered per account on this device.
@MainActor @Observable
final class PasskeyPromptModel {
    var isPresented = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let service: any PasskeyService
    @ObservationIgnored private let defaults: UserDefaults

    init(service: any PasskeyService, defaults: UserDefaults = .standard) { self.service = service; self.defaults = defaults }

    static func key(for userID: String) -> String { "passkeyPrompt.\(userID)" }

    func check(userID: String) async {
        guard PasskeySupport.isEnabled, defaults.string(forKey: Self.key(for: userID)) == nil else { return }
        guard let existing = try? await service.passkeys() else { return } // Ask again next time.
        if existing.isEmpty { isPresented = true } else { defaults.set("done", forKey: Self.key(for: userID)) }
    }
    func dismiss(userID: String) { defaults.set("dismissed", forKey: Self.key(for: userID)); isPresented = false }
    func add(userID: String) async {
        do {
            try await service.registerPasskey(name: nil)
            defaults.set("done", forKey: Self.key(for: userID))
        } catch {
            if let message = PasskeySupport.message(for: error, purpose: .register) { errorMessage = message }
        }
    }
    func clearError() { errorMessage = nil }
}
