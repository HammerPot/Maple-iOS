import SwiftUI

struct AddFriendView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var model: AddFriendModel
    @FocusState private var focused: Bool
    @ScaledMetric private var avatarSize = 56

    init(friends: FriendsModel, myID: String?, session: any SessionEnding) {
        _model = State(initialValue: AddFriendModel(friends: friends, myID: myID, session: session))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("@").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("Username", text: $model.username)
                            .accessibilityLabel("Username")
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .focused($focused)
                            .onSubmit { Task { await model.search() } }
                        if model.isSearching { ProgressView() }
                    }
                } footer: {
                    if let error = model.errorMessage, model.found == nil { FormMessage(text: error) }
                    else { Text("Enter their Maple username to send a friend request.") }
                }

                if model.found == nil {
                    Section {
                        Button { Task { await model.search() } } label: { BusyButtonLabel(title: "Find", busy: model.isSearching) }
                            .disabled(!model.canSearch)
                    }
                }

                if let profile = model.found {
                    Section {
                        HStack(spacing: 14) {
                            AvatarView(userID: profile.id).frame(width: min(avatarSize, 72), height: min(avatarSize, 72))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.label).font(.headline)
                                Text("@" + profile.username).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .padding(.vertical, 4)
                        action(for: profile)
                    } footer: {
                        if let error = model.errorMessage { FormMessage(text: error) }
                    }
                }
            }
            .accountFormKeyboard()
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .announcing(model.errorMessage)
            .onAppear { focused = true }
            .onChange(of: model.completion) { _, message in
                if let message { toasts.show(message); dismiss() }
            }
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }

    @ViewBuilder private func action(for profile: Profile) -> some View {
        switch model.relationship {
        case .me?:
            FormMessage(text: "That’s you.", kind: .hint)
        case .friend?:
            FormMessage(text: "You’re already friends.", kind: .success)
        case .requestSent?:
            FormMessage(text: "You’ve already sent \(profile.label) a request.", kind: .hint)
        case .requestReceived?:
            Button { Task { await model.accept() } } label: {
                BusyButtonLabel(title: "Accept \(profile.label)’s Request", busy: model.isSending)
            }
            .disabled(model.isSending)
        case .stranger?, nil:
            Button { Task { await model.send() } } label: {
                BusyButtonLabel(title: "Send Friend Request", busy: model.isSending)
            }
            .disabled(model.isSending)
        }
    }
}
