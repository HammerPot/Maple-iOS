import SwiftUI

struct PasskeysView: View {
    @State private var model: PasskeysModel
    @State private var renaming: PasskeyItem?
    @State private var newName = ""
    @State private var deleting: PasskeyItem?

    init(service: any PasskeyService) { _model = State(initialValue: PasskeysModel(service: service)) }

    var body: some View {
        List {
            Section {
                ForEach(model.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName).font(.headline)
                        Text("Added \(item.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions {
                        Button("Remove", role: .destructive) { deleting = item }
                        Button("Rename") { newName = item.name ?? ""; renaming = item }
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { newName = item.name ?? ""; renaming = item }
                        Button("Remove", systemImage: "trash", role: .destructive) { deleting = item }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in with Face ID, Touch ID or your device passcode instead of your password.")
                    if let status = model.statusMessage { FormMessage(text: status, kind: .success) }
                }
            }
            Section {
                Button { Task { await model.add() } } label: { BusyButtonLabel(title: "Add Passkey", busy: model.isBusy) }
                    .disabled(model.isBusy)
            }
        }
        .overlay {
            if model.hasLoaded && model.items.isEmpty {
                ContentUnavailableView("No Passkeys Yet", systemImage: "person.badge.key",
                                       description: Text("Add one to sign in without typing your password."))
                    .allowsHitTesting(false)
            } else if !model.hasLoaded && model.errorMessage == nil {
                ProgressView()
            }
        }
        .navigationTitle("Passkeys")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .alert("Rename Passkey", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { item in
            TextField("Name", text: $newName)
                .accessibilityLabel("Name")
            Button("Save") { Task { await model.rename(item, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove this passkey?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            Button("Remove \(item.displayName)", role: .destructive) { Task { await model.delete(item) } }
        } message: { _ in
            Text("You won’t be able to sign in with it anymore. It may still appear in your Passwords app until you delete it there.")
        }
        .alert("Passkeys", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }
}

private struct PasskeyPromptModifier: ViewModifier {
    let userID: String
    @State private var model: PasskeyPromptModel

    init(userID: String, service: any PasskeyService) {
        self.userID = userID
        _model = State(initialValue: PasskeyPromptModel(service: service))
    }

    func body(content: Content) -> some View {
        content
            .task(id: userID) { await model.check(userID: userID) }
            .alert("Add a passkey?", isPresented: $model.isPresented) {
                Button("Not Now", role: .cancel) { model.dismiss(userID: userID) }
                Button("Add Passkey") { Task { await model.add(userID: userID) } }
            } message: {
                Text("Sign in with Face ID, Touch ID or your device passcode instead of your password. You can manage passkeys in Password & Security.")
            }
            .alert("The passkey was not added.", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.errorMessage ?? "") }
    }
}

extension View {
    /// Shows the one-time "Add a passkey?" prompt when passkeys are enabled and the account has none.
    @ViewBuilder func passkeyPrompt(userID: String, session: any PasskeyService) -> some View {
        if PasskeySupport.isEnabled { modifier(PasskeyPromptModifier(userID: userID, service: session)) }
        else { self }
    }
}
