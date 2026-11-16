import SwiftUI

struct LegacyEnrollmentView: View {
    let session: any SignInService
    @Environment(\.dismiss) private var dismiss
    @State private var model: LegacyEnrollmentModel

    init(context: LegacyContext, session: any SignInService) {
        self.session = session
        _model = State(initialValue: LegacyEnrollmentModel(context: context, session: session))
    }

    var body: some View {
        if let verification = model.verification {
            VerifyEmailView(context: verification, session: session)
        } else {
            form
        }
    }

    private var form: some View {
        @Bindable var model = model
        return Form {
            if model.fromSignIn {
                Section {
                    LabeledContent("Account", value: model.username.isEmpty ? "No username" : model.username)
                } header: {
                    AccountFormHeader(title: "Add Your Email",
                                      subtitle: "Maple accounts now need a verified email address. Add one to finish moving your account.",
                                      systemImage: "person.crop.circle.badge.checkmark")
                }
            } else {
                Section {
                    TextField("Original Username", text: $model.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                } header: {
                    AccountFormHeader(title: "Move Your Account",
                                      subtitle: "Maple accounts now need a verified email address. Add one to finish moving your account.",
                                      systemImage: "person.crop.circle.badge.checkmark")
                } footer: {
                    Text("Enter your username exactly as before, or leave it empty if your old username was blank.")
                }
            }

            Section {
                TextField("Email", text: $model.email)
                    .identifierField(email: true)
            } footer: {
                if let error = model.emailError { FormMessage(text: error) }
                else { Text("We’ll send a verification link to this address.") }
            }

            if model.needsNewUsername {
                Section {
                    TextField("New Username", text: $model.newUsername)
                        .textContentType(.username)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("New Username")
                } footer: {
                    if let error = model.newUsernameError { FormMessage(text: error) }
                    else { Text(AccountRules.usernameHint) }
                }
            }

            Section {
                Button { Task { await model.enroll() } } label: {
                    BusyButtonLabel(title: "Send Verification Link", busy: model.isBusy)
                }
                .disabled(!model.canSubmit)
                if model.alreadyEnrolled {
                    Button("Back to Sign In") { dismiss() }
                }
            } footer: {
                if let error = model.errorMessage { FormMessage(text: error) }
            }
        }
        .navigationTitle("Move Account")
        .navigationBarTitleDisplayMode(.inline)
        .announcing(model.errorMessage)
        .animation(.default, value: model.needsNewUsername)
        .disabled(model.isBusy)
    }
}
