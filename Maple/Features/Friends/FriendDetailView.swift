import SwiftUI

struct FriendDetailView: View {
    let id: String
    let model: FriendsScreenModel
    @Environment(\.dismiss) private var dismiss
    @State private var removing: Profile?
    @ScaledMetric private var avatarSize = 88

    var body: some View {
        if let friend = model.friends.friend(id: id) {
            List {
                Section {
                    VStack(spacing: 8) {
                        AvatarView(userID: friend.id).frame(width: min(avatarSize, 112), height: min(avatarSize, 112))
                        Text(friend.profile.label).font(.title2.bold())
                        if friend.profile.label != friend.username {
                            Text("@" + friend.username).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
                .listRowBackground(Color.clear)

                Section {
                    ListeningCard(userID: friend.id, status: ListeningStatus(friend.listening), receivedAt: model.receivedAt(friend.id),
                                  hiddenText: "\(friend.profile.label) keeps their listening activity private.")
                        .padding(.vertical, 8)
                }

                Section {
                    Button(role: .destructive) { removing = friend.profile } label: {
                        BusyButtonLabel(title: "Remove Friend", busy: model.pending.contains(friend.id))
                    }
                    .disabled(model.pending.contains(friend.id))
                }
            }
            .navigationTitle(friend.profile.label)
            .navigationBarTitleDisplayMode(.inline)
            .removeFriendDialog($removing, model: model) { dismiss() }
        } else {
            ContentUnavailableView("Not Friends", systemImage: "person.crop.circle.badge.xmark",
                                   description: Text("You’re no longer friends with this person."))
        }
    }
}

struct RequestsView: View {
    let model: FriendsScreenModel

    var body: some View {
        List {
            if !model.friends.requests.incoming.isEmpty {
                Section {
                    ForEach(model.friends.requests.incoming) { profile in
                        RequestRow(profile: profile, busy: model.pending.contains(profile.id)) {
                            Button("Accept") { Task { await model.accept(profile) } }
                                .buttonStyle(.borderedProminent)
                            Button("Decline", systemImage: "xmark") { Task { await model.decline(profile) } }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.bordered)
                        }
                        .accessibilityAction(named: "Accept") { Task { await model.accept(profile) } }
                        .accessibilityAction(named: "Decline") { Task { await model.decline(profile) } }
                    }
                } header: {
                    Text("Received")
                } footer: {
                    Text("Accepting lets you see each other’s listening activity.")
                }
            }
            if !model.friends.requests.outgoing.isEmpty {
                Section("Sent") {
                    ForEach(model.friends.requests.outgoing) { profile in
                        RequestRow(profile: profile, busy: model.pending.contains(profile.id)) {
                            Button("Cancel") { Task { await model.cancel(profile) } }
                                .buttonStyle(.bordered)
                        }
                        .accessibilityAction(named: "Cancel Request") { Task { await model.cancel(profile) } }
                    }
                }
            }
        }
        .overlay {
            if !model.hasRequests {
                ContentUnavailableView("No Requests", systemImage: "person.crop.circle.badge.checkmark",
                                       description: Text("Friend requests you send or receive appear here."))
            }
        }
        .navigationTitle("Friend Requests")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }
}

private struct RequestRow<Actions: View>: View {
    let profile: Profile
    let busy: Bool
    @ViewBuilder let actions: Actions
    @ScaledMetric private var avatarSize = 40

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(userID: profile.id).frame(width: min(avatarSize, 112), height: min(avatarSize, 112))
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.label).font(.headline).lineLimit(1)
                Text("@" + profile.username).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if busy { ProgressView() } else { HStack(spacing: 8) { actions } }
        }
    }
}
