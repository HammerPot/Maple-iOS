import SwiftUI

struct ForgotPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ForgotPasswordModel

    init(email: String, session: any SignInService) {
        _model = State(initialValue: ForgotPasswordModel(email: email, session: session))
    }

    var body: some View {
        @Bindable var model = model
        Form {
            if let sentTo = model.sentTo {
                Section {
                    Text("If an account uses \(sentTo), we sent it a link to reset your password.")
                    Text("Open the link to choose a new password in your browser. Then come back here and sign in with it.")
                        .foregroundStyle(.secondary)
                } header: {
                    AccountFormHeader(title: "Check Your Email", subtitle: "The reset link expires after a while.", systemImage: "envelope.badge")
                }
                Section {
                    Button("Back to Sign In") { dismiss() }.frame(maxWidth: .infinity)
                    Button("Use a Different Email") { model.startOver() }.frame(maxWidth: .infinity)
                }
            } else {
                Section {
                    TextField("Email", text: $model.email)
                        .identifierField(email: true)
                        .submitLabel(.send)
                        .onSubmit { Task { await model.send() } }
                } header: {
                    AccountFormHeader(title: "Reset Password", subtitle: "Enter your account email and we’ll send you a reset link.",
                                      systemImage: "key.horizontal")
                } footer: {
                    if let error = model.emailError ?? model.errorMessage { FormMessage(text: error) }
                    else { Text("You’ll choose the new password in your browser.") }
                }
                Section {
                    Button { Task { await model.send() } } label: {
                        BusyButtonLabel(title: "Send Reset Link", busy: model.isBusy)
                    }
                    .disabled(!model.canSubmit)
                }
            }
        }
        .navigationTitle("Reset Password")
        .navigationBarTitleDisplayMode(.inline)
        .announcing(model.errorMessage)
        .disabled(model.isBusy)
    }
}
