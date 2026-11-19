import SwiftUI

struct EditDisplayNameView: View {
    let model: ProfileModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool
    private let original: String

    init(current: String, model: ProfileModel) {
        self.model = model
        original = current
        _name = State(initialValue: current)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var problem: String? { AccountRules.displayNameProblem(name) }
    private var canSave: Bool { problem == nil && trimmed != original && !model.isSavingName }

    var body: some View {
        Form {
            Section {
                TextField("Display Name", text: $name)
                    .accessibilityLabel("Display Name")
                    .textContentType(.name)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit { Task { await save() } }
            } footer: {
                if let error = model.nameError { FormMessage(text: error) }
                else if trimmed != original, let problem { FormMessage(text: problem) }
                else { Text("Friends see this instead of your username. Up to 64 characters.") }
            }
        }
        .accountFormKeyboard()
        .navigationTitle("Display Name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if model.isSavingName { ProgressView() }
                else { Button("Save") { Task { await save() } }.disabled(!canSave) }
            }
        }
        .onAppear { focused = true }
        .disabled(model.isSavingName)
    }

    private func save() async {
        guard canSave else { return }
        if await model.saveDisplayName(trimmed) { dismiss() }
    }
}
