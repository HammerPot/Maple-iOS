import SwiftUI

/// A stored session is kept until Maple can verify it or the person explicitly signs out.
struct SessionUnreachableView: View {
    @Environment(AuthSessionModel.self) private var auth
    @Environment(ToastCenter.self) private var toasts
    @State private var isRetrying = false

    var body: some View {
        ScrollView {
            ContentUnavailableView {
                Label("Couldn't reach Maple", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Your saved session is still on this device. Check your connection and try again.")
            } actions: {
                Button {
                    isRetrying = true
                    Task {
                        await auth.retryRestore()
                        isRetrying = false
                    }
                } label: {
                    BusyButtonLabel(title: "Try Again", busy: isRetrying)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRetrying)
                Button("Sign Out", role: .destructive) {
                    Task {
                        do { try await auth.signOut() }
                        catch { toasts.show(error) }
                    }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }
}
