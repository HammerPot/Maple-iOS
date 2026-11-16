import SwiftUI

struct DeleteAccountView: View {
    @Environment(ToastCenter.self) private var toasts
    @State private var model: DeleteAccountModel
    @State private var confirms = false

    init(username: String, session: any AccountSecurityService) {
        _model = State(initialValue: DeleteAccountModel(username: username, session: session))
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("This can’t be undone.", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.red)
                    Text("Deleting your account permanently removes your Maple profile, display name and photo, friends and friend requests, listening activity and passkeys. Your friends will see that you’re gone.")
                    Text("Music on this device stays in your library.").foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section {
                TextField(model.username, text: $model.confirmation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Type your username, \(model.username), to confirm")
            } header: {
                Text("Type “\(model.username)” to Confirm")
            } footer: {
                if let error = model.errorMessage { FormMessage(text: error) }
            }
            Section {
                Button(role: .destructive) { confirms = true } label: {
                    BusyButtonLabel(title: "Delete Account", busy: model.isBusy)
                }
                .disabled(!model.canDelete)
            }
        }
        .accountFormKeyboard()
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .announcing(model.errorMessage)
        .disabled(model.isBusy)
        .confirmationDialog("Delete your Maple account?", isPresented: $confirms, titleVisibility: .visible) {
            Button("Delete Account Permanently", role: .destructive) {
                Task { if await model.delete() { toasts.show("Your Maple account was deleted.") } }
            }
        } message: {
            Text("@\(model.username) and everything connected to it will be removed.")
        }
    }
}
