import SwiftUI

struct FriendList: View {
    @Environment(FriendsModel.self) private var model
    @Environment(ToastCenter.self) private var toasts
    @State private var username = ""
    var body: some View {
        List {
            Section("Manage") {
                TextField("Friend's username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { run { try await model.sendRequest(username: username); username = "" } }
                Button("Add friend") { run { try await model.sendRequest(username: username); username = "" } }
            }
            Section("Requests") {
                ForEach(model.requests.incoming) { profile in
                    HStack {
                        row(profile)
                        Spacer()
                        Button("Accept", systemImage: "checkmark.circle.fill") { run { try await model.accept(id: profile.id) } }
                        Button("Decline", systemImage: "xmark.circle.fill") { run { try await model.declineOrCancel(id: profile.id) } }
                    }.buttonStyle(.borderless).labelStyle(.iconOnly)
                }
            }
            Section("Sent requests") {
                ForEach(model.requests.outgoing) { profile in
                    HStack { row(profile); Spacer(); Button("Cancel") { run { try await model.declineOrCancel(id: profile.id) } } }
                }
            }
            Section("Friends") {
                ForEach(model.friends) { friend in
                    VStack(alignment: .leading) {
                        row(friend.profile)
                        if let current = friend.listening?.current {
                            Text("\(current.title) – \(current.artist)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("Remove", role: .destructive) { run { try await model.remove(id: friend.id) } } }
                }
            }
        }
        .navigationTitle("Friends")
        .task { do { try await model.refresh() } catch { toasts.show(error) } }
        .refreshable { do { try await model.refresh() } catch { toasts.show(error) } }
    }
    private func row(_ profile: Profile) -> some View {
        HStack {
            AvatarView(userID: profile.id).frame(width: 40, height: 40)
            VStack(alignment: .leading) { Text(profile.label).font(.headline); Text("@" + profile.username).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action() } catch { toasts.show(error) } }
    }
}
