import SwiftUI

/// Content of the Account tab without its navigation stack: restoring, signed-out flow, or the signed-in profile.
struct AccountRoot: View {
    @Environment(AppServices.self) private var services
    @Environment(AuthSessionModel.self) private var auth

    var body: some View {
        if let user = auth.user {
            AccountHomeView(user: user, api: services.api, session: auth)
                .id(user.id)
        } else if auth.sessionUnreachable {
            SessionUnreachableView()
                .navigationTitle("Account")
        } else if auth.isRestoring {
            ProgressView("Restoring Session…")
                .navigationTitle("Account")
        } else {
            SignInView(session: auth)
        }
    }
}
