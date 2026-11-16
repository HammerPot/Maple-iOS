import Foundation
import Observation

/// Loads the account email for the Security screen.
@MainActor @Observable
final class SecurityModel {
    private(set) var email: String?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    @ObservationIgnored private let session: any AccountSecurityService
    init(session: any AccountSecurityService) { self.session = session }

    func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            guard let reply = try await session.currentSession() else { await session.invalidate(); return }
            email = reply.user.email; errorMessage = nil
        } catch {
            if AccountErrorCopy.endsSession(error) { await session.invalidate(); return }
            errorMessage = AccountErrorCopy.message(for: error)
        }
    }
}

@MainActor @Observable
final class ChangeEmailModel {
    let currentEmail: String?
    var newEmail = "" { didSet { if newEmail != oldValue { serverError = nil } } }
    private(set) var isBusy = false
    private(set) var sentTo: String?
    private var serverError: String?
    @ObservationIgnored private let session: any AccountSecurityService

    init(currentEmail: String?, session: any AccountSecurityService) { self.currentEmail = currentEmail; self.session = session }

    private var trimmed: String { newEmail.trimmingCharacters(in: .whitespacesAndNewlines) }
    var error: String? {
        if let serverError { return serverError }
        if trimmed.isEmpty { return nil }
        if let problem = AccountRules.emailProblem(trimmed) { return problem }
        if trimmed.caseInsensitiveCompare(currentEmail ?? "") == .orderedSame { return "That’s already your email address." }
        return nil
    }
    var canSubmit: Bool { !isBusy && !trimmed.isEmpty && error == nil }

    func submit() async {
        guard canSubmit else { return }
        let address = trimmed
        isBusy = true; defer { isBusy = false }
        do {
            try await session.changeEmail(address)
            sentTo = address; newEmail = ""
        } catch {
            if AccountErrorCopy.endsSession(error) { await session.invalidate(); return }
            serverError = AccountErrorCopy.message(for: error)
        }
    }
}

@MainActor @Observable
final class ChangePasswordModel {
    var currentPassword = "" { didSet { if currentPassword != oldValue { currentError = nil } } }
    var newPassword = "" { didSet { if newPassword != oldValue { newServerError = nil } } }
    /// On by default, like the web client.
    var signOutOtherDevices = true
    private(set) var isBusy = false
    private(set) var didChange = false
    private(set) var currentError: String?
    private(set) var errorMessage: String?
    private var newServerError: String?
    @ObservationIgnored private let session: any AccountSecurityService

    init(session: any AccountSecurityService) { self.session = session }

    var newError: String? {
        if let newServerError { return newServerError }
        if newPassword.isEmpty { return nil }
        if let problem = AccountRules.passwordProblem(newPassword) { return problem }
        if newPassword == currentPassword { return "Choose a password that’s different from your current one." }
        return nil
    }
    var canSubmit: Bool { !isBusy && !currentPassword.isEmpty && !newPassword.isEmpty && newError == nil && currentError == nil }

    func submit() async {
        guard canSubmit else { return }
        isBusy = true; errorMessage = nil; defer { isBusy = false }
        do {
            try await session.changePassword(current: currentPassword, new: newPassword, revokeOtherSessions: signOutOtherDevices)
            currentPassword = ""; newPassword = ""
            didChange = true
        } catch {
            if AccountErrorCopy.endsSession(error) { await session.invalidate(); return }
            let message = AccountErrorCopy.message(for: error)
            switch AccountErrorCopy.code(of: error) {
            case "INVALID_PASSWORD": currentError = message
            case "PASSWORD_POLICY", "PASSWORD_TOO_SHORT", "PASSWORD_TOO_LONG": newServerError = message
            default: errorMessage = message
            }
        }
    }
}

/// Signed-in devices, with revoke and "Sign Out Everywhere".
@MainActor @Observable
final class SessionsModel {
    struct Row: Identifiable, Equatable {
        let id: String
        let device: DeviceDescription
        let ipAddress: String?
        let lastActive: Date
        let signedInAt: Date
        let isCurrent: Bool
    }
    private(set) var rows: [Row] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var revoking: Set<String> = []
    private(set) var isSigningOutEverywhere = false
    var errorMessage: String?
    /// Tokens stay in memory only, keyed by session ID, and are never shown or logged.
    @ObservationIgnored private var tokens: [String: String] = [:]
    @ObservationIgnored private let session: any AccountSecurityService

    init(session: any AccountSecurityService) { self.session = session }

    var others: [Row] { rows.filter { !$0.isCurrent } }
    var current: Row? { rows.first(where: \.isCurrent) }

    func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            async let list = session.listSessions()
            async let current = session.currentSession()
            let (sessions, reply) = try await (list, current)
            guard let reply else { await session.invalidate(); return }
            tokens = Dictionary(sessions.map { ($0.id, $0.token) }, uniquingKeysWith: { first, _ in first })
            rows = sessions
                .map { Row(id: $0.id, device: DeviceDescription(userAgent: $0.userAgent), ipAddress: $0.ipAddress,
                           lastActive: $0.updatedAt, signedInAt: $0.createdAt, isCurrent: $0.id == reply.session.id) }
                .sorted { ($0.isCurrent ? 1 : 0, $0.lastActive) > ($1.isCurrent ? 1 : 0, $1.lastActive) }
            hasLoaded = true; errorMessage = nil
        } catch {
            if AccountErrorCopy.endsSession(error) { await session.invalidate(); return }
            errorMessage = AccountErrorCopy.message(for: error)
        }
    }

    func revoke(_ row: Row) async {
        guard !row.isCurrent, let token = tokens[row.id], !revoking.contains(row.id) else { return }
        revoking.insert(row.id); defer { revoking.remove(row.id) }
        do {
            try await session.revokeSession(token: token)
            rows.removeAll { $0.id == row.id }; tokens[row.id] = nil
        } catch {
            if AccountErrorCopy.endsSession(error) { await session.invalidate(); return }
            errorMessage = AccountErrorCopy.message(for: error)
        }
    }

    func signOutEverywhere() async {
        isSigningOutEverywhere = true; defer { isSigningOutEverywhere = false }
        do { try await session.signOutEverywhere() }
        catch {
            if AccountErrorCopy.endsSession(error) { await session.invalidate(); return }
            errorMessage = AccountErrorCopy.message(for: error)
        }
    }
}

@MainActor @Observable
final class DeleteAccountModel {
    let username: String
    var confirmation = ""
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let session: any AccountSecurityService

    init(username: String, session: any AccountSecurityService) { self.username = username; self.session = session }

    /// Requires the username typed exactly (case-insensitive, like sign-in).
    var isConfirmed: Bool {
        confirmation.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(username) == .orderedSame
    }
    var canDelete: Bool { isConfirmed && !isBusy }

    /// Returns true once the account is gone.
    func delete() async -> Bool {
        guard canDelete else { return false }
        isBusy = true; errorMessage = nil; defer { isBusy = false }
        do {
            try await session.deleteAccount()
            return true
        } catch {
            if AccountErrorCopy.endsSession(error) { await session.invalidate(); return false }
            errorMessage = AccountErrorCopy.message(for: error)
            return false
        }
    }
}
