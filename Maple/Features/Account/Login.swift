import SwiftUI

/// Compatibility entry point for the pre-refresh shell, which still embeds `Login()` in its own
/// navigation stack. It shows the same content as `AccountTab`, and — because that shell has no Friends
/// tab — a toolbar link to Friends. Delete once the shell uses `AccountTab()` and `FriendsTab()`.
struct Login: View {
    var body: some View {
        AccountRoot()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        FriendsRoot()
                    } label: {
                        Label("Friends", systemImage: "person.2")
                    }
                }
                #if DEBUG
                if AccountVerificationSupport.showsChecks {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink("Account Checks") { AccountVerificationChecks() }
                    }
                }
                #endif
            }
    }
}
