import SwiftUI

/// Root of the Account tab. Owns its own navigation stack; the app shell only ever references `AccountTab()`.
struct AccountTab: View {
    var body: some View {
        NavigationStack {
            AccountRoot()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            Settings()
                        } label: {
                            Label("Settings", systemImage: "gear")
                        }
                    }
                }
        }
    }
}
