import SwiftUI

struct VerifyEmailView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: VerifyEmailModel
    @State private var showsChangeEmail = false

    init(context: VerificationContext, session: any SignInService) {
        _model = State(initialValue: VerifyEmailModel(context: context, session: session))
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Text("Open the link on this device or another device. Verification finishes in your browser — then come back to Maple.")
                    .foregroundStyle(.secondary)
            } header: {
                AccountFormHeader(title: "Check Your Email", subtitle: sentLine, systemImage: "envelope.badge")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let status = model.statusMessage { FormMessage(text: status, kind: .success) }
                    if let error = model.errorMessage { FormMessage(text: error) }
                }
            }

            Section {
                if model.context.canSignIn {
                    Button { Task { await model.continueAfterVerifying() } } label: {
                        BusyButtonLabel(title: "I’ve Verified My Email", busy: model.isBusy)
                    }
                    .disabled(model.isBusy)
                }
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let wait = model.secondsUntilResend(at: timeline.date)
                    Button(wait > 0 ? "Resend Email in \(MapleFormat.duration(Double(wait)))" : "Resend Email") {
                        Task { await model.resend() }
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(wait > 0 || model.isBusy)
                }
            } footer: {
                if model.context.canSignIn {
                    Text("Maple also checks automatically while this screen is open.")
                }
            }

            if model.context.canChangeEmail {
                Section {
                    if showsChangeEmail {
                        TextField("New Email Address", text: $model.newEmail)
                            .accessibilityLabel("New Email Address")
                            .identifierField(email: true)
                            .submitLabel(.send)
                            .onSubmit { Task { await sendToNewEmail() } }
                        Button { Task { await sendToNewEmail() } } label: {
                            BusyButtonLabel(title: "Send Link", busy: model.isBusy)
                        }
                        .disabled(!model.canChangeEmail)
                    } else {
                        Button("Use a Different Email") { withAnimation(reduceMotion ? nil : .default) { showsChangeEmail = true } }
                    }
                } footer: {
                    if let problem = model.changeEmailError ?? model.newEmailProblem { FormMessage(text: problem) }
                }
            }

            Section {
                Button("Back to Sign In") { dismiss() }
            }
        }
        .accountFormKeyboard()
        .navigationTitle("Verify Email")
        .navigationBarTitleDisplayMode(.inline)
        .announcing(model.statusMessage ?? model.errorMessage)
        .task { await model.poll() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.check() } }
        }
        .onChange(of: model.needsSignIn) { _, needs in if needs { dismiss() } }
    }

    private var sentLine: String {
        if let email = model.context.email { return "We sent a verification link to \(email)." }
        return "We sent a verification link to your email address."
    }
    private func sendToNewEmail() async {
        if await model.changeEmail() { withAnimation(reduceMotion ? nil : .default) { showsChangeEmail = false } }
    }
}
