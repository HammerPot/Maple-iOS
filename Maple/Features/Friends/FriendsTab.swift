import SwiftUI

/// Root of the Friends tab. Owns its own navigation stack; the app shell only ever references `FriendsTab()`.
struct FriendsTab: View {
    var body: some View {
        NavigationStack {
            FriendsRoot()
        }
    }
}
