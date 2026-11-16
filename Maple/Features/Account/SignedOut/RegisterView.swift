import SwiftUI

struct RegisterView: View {
    let session: any SignInService
    @State private var model: RegisterModel
    @FocusState private var focus: Field?
    private enum Field { case email, username, password }

    init(session: any SignInService) {
        self.session = session
        _model = State(initialValue: RegisterModel(session: session))
    }

    var body: some View {
        if let verification = model.verification {
            // The pending screen replaces the form, so Back returns to sign-in.
            VerifyEmailView(context: verification, session: session)
        } else {
            form
        }
    }

    private var form: some View {
        @Bindable var model = model
        return Form {
            Section {
                TextField("Email", text: $model.email)
                    .identifierField(email: true)
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .username }
            } header: {
                AccountFormHeader(title: "Create Account", subtitle: "Join Maple to start listening with friends.")
            } footer: {
                if let error = model.emailError { FormMessage(text: error) }
                else { Text("You’ll need to verify this address before you can sign in.") }
            }
            Section {
                TextField("Username", text: $model.username)
                    .textContentType(.username)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
            } footer: {
                if let error = model.usernameError { FormMessage(text: error) }
                else { Text(AccountRules.usernameHint + " You can’t change it later.") }
            }
            Section {
                SecureField("Password", text: $model.password)
                    .textContentType(.newPassword)
                    .focused($focus, equals: .password)
                    .submitLabel(.join)
                    .onSubmit { Task { await model.register() } }
            } footer: {
                if let error = model.passwordError { FormMessage(text: error) }
                else { Text(AccountRules.passwordHint) }
            }
            Section {
                Button { Task { await model.register() } } label: {
                    BusyButtonLabel(title: "Create Account", busy: model.isBusy)
                }
                .disabled(!model.canSubmit)
            } footer: {
                if let error = model.errorMessage { FormMessage(text: error) }
            }
        }
        .navigationTitle("Create Account")
        .navigationBarTitleDisplayMode(.inline)
        .announcing(model.errorMessage)
        .disabled(model.isBusy)
    }
}
