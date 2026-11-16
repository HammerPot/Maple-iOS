import SwiftUI
import PhotosUI

struct Login: View {
    @Environment(AuthSessionModel.self) private var auth
    @Environment(ToastCenter.self) private var toasts
    @State private var username = ""
    @State private var password = ""
    @State private var email = ""
    @State private var newUsername = ""
    @State private var busy = false
    @State private var showRegister = false

    var body: some View {
        Group {
            if auth.user != nil { LoggedIn() }
            else if auth.isRestoring { ProgressView("Restoring session…") }
            else {
                ScrollView {
                    VStack(spacing: 20) {
                        TextField("Username or email", text: $username)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $password).textContentType(.password).onSubmit { signIn() }
                        if case .needsEmailVerification = auth.state {
                            Text("Open your verification email in your browser, then return here and sign in.")
                            TextField("Email", text: $email).textContentType(.emailAddress).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                            Button("Resend verification email") { run { try await auth.resendVerification(email: email); toasts.show("Verification email sent.") } }
                        }
                        if auth.needsLegacyEnrollment {
                            TextField("Email", text: $email).textContentType(.emailAddress).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                            TextField("New username (only if required)", text: $newUsername).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Finish moving account") {
                                run { try await auth.enrollLegacy(username: username, password: password, email: email, newUsername: newUsername.isEmpty ? nil : newUsername); password = "" }
                            }
                        }
                        Button("Login") { signIn() }.buttonStyle(.borderedProminent)
                        Button("Sign in with passkey") { run { try await auth.signInWithPasskey() } }
                        Button("Register") { showRegister = true }
                        Button("Forgot password?") {
                            run {
                                guard !email.isEmpty || username.contains("@") else {
                                    toasts.show("Enter your email in the username field to request a password reset."); return
                                }
                                try await auth.requestPasswordReset(email: email.isEmpty ? username : email)
                                toasts.show("Check your email to reset your password in your browser.")
                            }
                        }
                        if busy { ProgressView() }
                    }
                    .textFieldStyle(.roundedBorder).padding().disabled(busy)
                }
                .sheet(isPresented: $showRegister) { RegisterSheet() }
            }
        }
        .navigationTitle("Account")
    }
    private func signIn() { run { try await auth.signIn(identifier: username, password: password); password = "" } }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await action() } catch { toasts.show(error) } }
    }
}

struct LoggedIn: View {
    @Environment(AppServices.self) private var services
    @Environment(AuthSessionModel.self) private var auth
    @Environment(ToastCenter.self) private var toasts
    @State private var name = ""
    @State private var photo: PhotosPickerItem?
    @State private var confirmDeletion = false
    @State private var busy = false
    var body: some View {
        List {
            if let user = auth.user {
                Section {
                    HStack {
                        AvatarView(userID: user.id, data: user.pfp).frame(width: 64, height: 64)
                        VStack(alignment: .leading) { Text(user.profile.label).font(.headline); Text("@" + user.username).foregroundStyle(.secondary) }
                    }
                    TextField("Display name", text: $name)
                    Button("Change display name") { run { try await services.api.setDisplayName(name); try await auth.refresh() } }
                    PhotosPicker("Change profile picture", selection: $photo, matching: .images)
                } header: { Text("Profile") }
                Section {
                    NavigationLink("Friends") { FriendList() }
                    Button("Sign out") { run { try await auth.signOut() } }
                    Button("Delete account", role: .destructive) { confirmDeletion = true }
                }
            }
            if busy { ProgressView() }
        }
        .disabled(busy)
        .onAppear { name = auth.user?.profile.label ?? "" }
        .onChange(of: photo) {
            run {
                if let data = try await photo?.loadTransferable(type: Data.self) {
                    try await services.api.setAvatar(data); try await auth.refresh()
                }
            }
        }
        .alert("Delete your Maple account permanently?", isPresented: $confirmDeletion) {
            Button("Delete account", role: .destructive) { run { try await auth.deleteAccount() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This deletes your profile and friendships. This cannot be undone.") }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await action() } catch { toasts.show(error) } }
    }
}

struct RegisterSheet: View {
    @Environment(AuthSessionModel.self) private var auth
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Username", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $password).textContentType(.newPassword)
                Text("Use 2–32 letters, numbers, dots, underscores, or hyphens for your username. Passwords need 8–128 characters with uppercase and lowercase letters.").font(.footnote)
                Button("Register") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await auth.signUp(username: username, email: email, password: password); password = ""; dismiss() }
                        catch { toasts.show(error) }
                    }
                }
                if busy { ProgressView() }
            }
            .disabled(busy).navigationTitle("Register")
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}
