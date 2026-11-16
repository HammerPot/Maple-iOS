import Foundation
import Observation
import OSLog

@MainActor @Observable
final class ProfileModel {
    private(set) var isUploadingPhoto = false
    private(set) var isSavingName = false
    private(set) var isSavingVisibility = false
    /// Local mirror of the server visibility so the toggle responds immediately; reverted on failure.
    var sharesListening: Bool
    /// A failure to show in an alert. Nothing fails silently.
    var alertMessage: String?
    /// Display-name failures are shown inline on the edit screen instead.
    private(set) var nameError: String?

    @ObservationIgnored private let api: any AccountProfileService
    @ObservationIgnored private let session: any AccountSecurityService
    @ObservationIgnored private let logger = Logger(subsystem: "dev.hammerpot.Maple-iOS", category: "Account")

    init(api: any AccountProfileService, session: any AccountSecurityService) {
        self.api = api; self.session = session
        sharesListening = session.user?.listeningVisibility != .private
    }

    func syncFromUser() {
        guard !isSavingVisibility else { return }
        sharesListening = session.user?.listeningVisibility != .private
    }

    /// Returns true when the name was saved.
    func saveDisplayName(_ name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        nameError = nil
        if let problem = AccountRules.displayNameProblem(trimmed) { nameError = problem; return false }
        isSavingName = true; defer { isSavingName = false }
        do {
            try await api.setDisplayName(trimmed)
            try await session.refresh()
            return true
        } catch {
            if AccountErrorCopy.endsSession(error) { await session.invalidate() }
            else { nameError = AccountErrorCopy.message(for: error) }
            return false
        }
    }

    func uploadPhoto(_ data: Data?) async {
        guard let data, !data.isEmpty else {
            alertMessage = "That photo couldn’t be loaded. Choose a different one."; return
        }
        isUploadingPhoto = true; defer { isUploadingPhoto = false }
        do {
            // `setAvatar` converts other formats and oversized images to a JPEG under 3 MB before uploading.
            try await api.setAvatar(data)
            try await session.refresh()
        } catch {
            await fail(error, context: "profile photo")
        }
    }

    func setSharesListening(_ shares: Bool) async {
        let previous = session.user?.listeningVisibility != .private
        guard shares != previous else { return }
        sharesListening = shares
        isSavingVisibility = true; defer { isSavingVisibility = false }
        do {
            try await api.setListeningVisibility(shares ? .public : .private)
            try await session.refresh()
        } catch {
            sharesListening = previous
            await fail(error, context: "listening visibility")
        }
    }

    private func fail(_ error: Error, context: String) async {
        logger.error("Updating \(context, privacy: .public) failed: status \(AccountErrorCopy.status(of: error) ?? 0, privacy: .public)")
        if AccountErrorCopy.endsSession(error) { await session.invalidate(); return }
        alertMessage = AccountErrorCopy.message(for: error)
    }
}
