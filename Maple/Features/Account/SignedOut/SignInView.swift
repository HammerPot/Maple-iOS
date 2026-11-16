import SwiftUI

/// Root of the signed-out flow. Registers the destinations for every signed-out screen.
struct SignInView: View {
    @Environment(AuthSessionModel.self) private var auth
    @State private var model: SignInModel
    @FocusState private var focus: Field?
    private enum Field { case identifier, password }

    init(session: any SignInService) { _model = State(initialValue: SignInModel(session: session)) }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Email or Username", text: $model.identifier)
                    .identifierField()
                    .focused($focus, equals: .identifier)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $model.password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await model.signIn() } }
            } header: {
                AccountFormHeader(title: "Welcome Back", subtitle: "Sign in to see what your friends are playing and share what you’re listening to.")
            } footer: {
                if let message = model.errorMessage { FormMessage(text: message) }
                else if case .needsEmailVerification = auth.state {
                    FormMessage(text: "Verify your email to finish signing in. Open the link we sent, then sign in again.", kind: .hint)
                }
            }

            Section {
                Button { Task { await model.signIn() } } label: {
                    BusyButtonLabel(title: "Sign In", busy: model.isBusy)
                }
                .disabled(!model.canSubmit)
                if PasskeySupport.isEnabled {
                    Button { Task { await model.signInWithPasskey() } } label: {
                        Label("Sign In with a Passkey", systemImage: "person.badge.key").frame(maxWidth: .infinity)
                    }
                    .disabled(model.isBusy)
                }
            }

            Section {
                NavigationLink("Forgot Password?", value: SignedOutRoute.forgotPassword(email: model.isEmail ? model.identifier : ""))
                NavigationLink("Create Account", value: SignedOutRoute.register)
                NavigationLink("Move an Existing Account", value: SignedOutRoute.legacy(LegacyContext()))
            } footer: {
                Text("Had a Maple account before email sign-in? Sign in with your old username and password and we’ll help you move it.")
            }
        }
        .navigationTitle("Account")
        .announcing(model.errorMessage)
        .onChange(of: model.identifier) { model.clearError() }
        .navigationDestination(for: SignedOutRoute.self) { SignedOutDestination(route: $0) }
        .navigationDestination(item: $model.route) { SignedOutDestination(route: $0) }
        .disabled(model.isBusy)
    }
}

struct SignedOutDestination: View {
    @Environment(AuthSessionModel.self) private var auth
    let route: SignedOutRoute
    var body: some View {
        switch route {
        case .register: RegisterView(session: auth)
        case .forgotPassword(let email): ForgotPasswordView(email: email, session: auth)
        case .legacy(let context): LegacyEnrollmentView(context: context, session: auth)
        case .verify(let context): VerifyEmailView(context: context, session: auth)
        }
    }
}
