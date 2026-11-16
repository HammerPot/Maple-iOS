import SwiftUI

struct SecurityView: View {
    let session: any AccountSecurityService
    @Environment(AuthSessionModel.self) private var auth
    @State private var model: SecurityModel

    init(session: any AccountSecurityService) {
        self.session = session
        _model = State(initialValue: SecurityModel(session: session))
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Email") {
                    if let email = model.email { Text(email).privacySensitive() }
                    else if model.isLoading { ProgressView() }
                    else { Text("Not Available") }
                }
                NavigationLink("Change Email") { ChangeEmailView(currentEmail: model.email, session: session) }
            } header: {
                Text("Email")
            } footer: {
                if let error = model.errorMessage { FormMessage(text: error) }
            }

            Section("Password") {
                NavigationLink("Change Password") { ChangePasswordView(session: session) }
            }

            if PasskeySupport.isEnabled {
                Section {
                    NavigationLink { PasskeysView(service: auth) } label: {
                        Label("Passkeys", systemImage: "person.badge.key")
                    }
                } footer: {
                    Text("Sign in with Face ID, Touch ID or your device passcode instead of your password.")
                }
            }

            Section {
                NavigationLink { SessionsView(session: session) } label: {
                    Label("Signed-In Devices", systemImage: "laptopcomputer.and.iphone")
                }
            } footer: {
                Text("See where you’re signed in, and sign out devices you don’t recognize.")
            }

            Section {
                NavigationLink {
                    if let user = auth.user { DeleteAccountView(username: user.username, session: session) }
                } label: {
                    Text("Delete Account").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Password & Security")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
    }
}

struct ChangeEmailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChangeEmailModel

    init(currentEmail: String?, session: any AccountSecurityService) {
        _model = State(initialValue: ChangeEmailModel(currentEmail: currentEmail, session: session))
    }

    var body: some View {
        @Bindable var model = model
        Form {
            if let sentTo = model.sentTo {
                Section {
                    Text("Open the link we sent to \(sentTo) to confirm your new email.")
                    if let current = model.currentEmail {
                        Text("Until you do, your account keeps using \(current).").foregroundStyle(.secondary)
                    }
                } header: {
                    AccountFormHeader(title: "Check Your Email", subtitle: "Confirmation finishes in your browser.", systemImage: "envelope.badge")
                }
                Section { Button("Done") { dismiss() }.frame(maxWidth: .infinity) }
            } else {
                if let current = model.currentEmail {
                    Section("Current Email") { Text(current).privacySensitive() }
                }
                Section {
                    TextField("New Email Address", text: $model.newEmail)
                        .identifierField(email: true)
                        .submitLabel(.send)
                        .onSubmit { Task { await model.submit() } }
                } header: {
                    Text("New Email")
                } footer: {
                    if let error = model.error { FormMessage(text: error) }
                    else { Text("We’ll send a confirmation link to the new address. Your email changes once you open it.") }
                }
                Section {
                    Button { Task { await model.submit() } } label: { BusyButtonLabel(title: "Change Email", busy: model.isBusy) }
                        .disabled(!model.canSubmit)
                }
            }
        }
        .navigationTitle("Change Email")
        .navigationBarTitleDisplayMode(.inline)
        .announcing(model.error)
        .disabled(model.isBusy)
    }
}

struct ChangePasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var model: ChangePasswordModel

    init(session: any AccountSecurityService) { _model = State(initialValue: ChangePasswordModel(session: session)) }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                SecureField("Current Password", text: $model.currentPassword).textContentType(.password)
            } footer: {
                if let error = model.currentError { FormMessage(text: error) }
            }
            Section {
                SecureField("New Password", text: $model.newPassword).textContentType(.newPassword)
            } footer: {
                if let error = model.newError { FormMessage(text: error) }
                else { Text(AccountRules.passwordHint) }
            }
            Section {
                Toggle("Sign Out Other Devices", isOn: $model.signOutOtherDevices)
            } footer: {
                Text("Recommended if you think someone else knows your password. This device stays signed in.")
            }
            Section {
                Button { Task { await model.submit() } } label: { BusyButtonLabel(title: "Change Password", busy: model.isBusy) }
                    .disabled(!model.canSubmit)
            } footer: {
                if let error = model.errorMessage { FormMessage(text: error) }
            }
        }
        .navigationTitle("Change Password")
        .navigationBarTitleDisplayMode(.inline)
        .announcing(model.currentError ?? model.errorMessage)
        .disabled(model.isBusy)
        .onChange(of: model.didChange) { _, changed in
            if changed { toasts.show("Your password was changed."); dismiss() }
        }
    }
}
