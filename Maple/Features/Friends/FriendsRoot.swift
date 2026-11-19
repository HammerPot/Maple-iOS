import SwiftUI

/// Content of the Friends tab without its navigation stack.
struct FriendsRoot: View {
    @Environment(AuthSessionModel.self) private var auth
    @Environment(FriendsModel.self) private var friends
    @Environment(ToastCenter.self) private var toasts
    @State private var showsSignIn = false

    var body: some View {
        Group {
            if let user = auth.user {
                FriendsListView(friends: friends, session: auth, myID: user.id, report: { toasts.show($0) })
                    .id(user.id)
            } else if auth.sessionUnreachable {
                SessionUnreachableView()
            } else if auth.isRestoring {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("Sign In to See Friends", systemImage: "person.2")
                } description: {
                    Text("See what your friends are listening to right now, and share what you’re playing.")
                } actions: {
                    Button("Sign In") { showsSignIn = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Friends")
        .sheet(isPresented: $showsSignIn) {
            NavigationStack {
                SignInView(session: auth)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showsSignIn = false } }
                    }
            }
        }
        .onChange(of: auth.user?.id) { _, id in if id != nil { showsSignIn = false } }
    }
}

struct FriendsListView: View {
    @State private var model: FriendsScreenModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsAddFriend = false
    @State private var removing: Profile?
    private let session: any SessionEnding
    private let myID: String

    init(friends: FriendsModel, session: any SessionEnding, myID: String, report: @escaping @MainActor (String) -> Void) {
        self.session = session; self.myID = myID
        _model = State(initialValue: FriendsScreenModel(friends: friends, session: session, report: report))
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    RequestsView(model: model)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Friend Requests", systemImage: "person.crop.circle.badge.plus")
                        if model.hasRequests {
                            Text(requestSummary).font(.subheadline).foregroundStyle(.secondary)
                                .padding(.leading, 36)
                        }
                    }
                }
                .badge(model.incomingCount)
                .accessibilityLabel("Friend Requests, \(requestSummary)")
            }
            if !model.listeningNow.isEmpty {
                Section("Listening Now") { rows(model.listeningNow) }
            }
            if !model.others.isEmpty {
                Section(model.listeningNow.isEmpty ? "Friends" : "Other Friends") { rows(model.others) }
            }
        }
        .animation(reduceMotion ? nil : .default, value: model.listeningNow.map(\.id))
        .overlay { overlay }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Friend", systemImage: "person.badge.plus") { showsAddFriend = true }
            }
        }
        .sheet(isPresented: $showsAddFriend) {
            AddFriendView(friends: model.friends, myID: myID, session: session)
        }
        .task { if !model.friends.hasLoaded { await model.load() } }
        .refreshable { await model.load() }
        .removeFriendDialog($removing, model: model)
    }

    private var requestSummary: String {
        var parts: [String] = []
        if model.incomingCount > 0 { parts.append("\(model.incomingCount) received") }
        if model.outgoingCount > 0 { parts.append("\(model.outgoingCount) sent") }
        return parts.isEmpty ? "No pending requests" : parts.joined(separator: " · ")
    }

    private func rows(_ list: [ListeningProfile]) -> some View {
        ForEach(list) { friend in
            NavigationLink {
                FriendDetailView(id: friend.id, model: model)
            } label: {
                FriendRow(friend: friend, receivedAt: model.receivedAt(friend.id))
            }
            .swipeActions {
                Button("Remove", role: .destructive) { removing = friend.profile }
            }
            .contextMenu {
                Button("Remove Friend", systemImage: "person.badge.minus", role: .destructive) { removing = friend.profile }
            }
            .accessibilityAction(named: "Remove Friend") { removing = friend.profile }
        }
    }

    @ViewBuilder private var overlay: some View {
        if !model.friends.hasLoaded {
            if let error = model.loadError {
                ContentUnavailableView {
                    Label("Couldn’t Load Friends", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await model.load() } }.buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("Loading Friends…")
            }
        } else if model.showsEmptyState && !model.hasRequests {
            ContentUnavailableView {
                Label("No Friends Yet", systemImage: "person.2")
            } description: {
                Text("Add someone by their username to see what they’re listening to.")
            } actions: {
                Button("Add Friend") { showsAddFriend = true }.buttonStyle(.borderedProminent)
            }
        }
    }
}

struct FriendRow: View {
    let friend: ListeningProfile
    let receivedAt: Date
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric private var avatarSize = 44
    @ScaledMetric private var artworkSize = 44

    var body: some View {
        let status = ListeningStatus(friend.listening)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            AvatarView(userID: friend.id).frame(width: min(avatarSize, 64), height: min(avatarSize, 64))
            VStack(alignment: .leading, spacing: 3) {
                Text(friend.profile.label).font(.headline).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                switch status {
                case .current, .lastPlayed: ListeningLine(status: status, receivedAt: receivedAt)
                case .nothing, .hidden: Text("@" + friend.username).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            if !typeSize.isAccessibilitySize, let artwork = status.artworkID {
                ArtworkView(url: MapleAPI.artworkURL(userID: friend.id, artwork: artwork))
                    .frame(width: artworkSize, height: artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(isCurrent(status) ? 1 : 0.6)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .modifier(ListeningAccessibilityUpdate(playing: isPlaying(status)) { now in
            accessibilityText(status, now: now)
        })
    }

    private func isPlaying(_ status: ListeningStatus) -> Bool {
        if case .current(let current) = status { return current.playing }
        return false
    }

    private func isCurrent(_ status: ListeningStatus) -> Bool { if case .current = status { return true }; return false }

    private func accessibilityText(_ status: ListeningStatus, now: Date) -> String {
        var parts = [friend.profile.label]
        if friend.profile.label != friend.username { parts.append("@" + friend.username) }
        if let listening = ListeningAccessibility.label(status, receivedAt: receivedAt, now: now) { parts.append(listening) }
        return parts.joined(separator: ", ")
    }
}

extension View {
    /// Confirmation before removing a friend.
    func removeFriendDialog(_ removing: Binding<Profile?>, model: FriendsScreenModel, onRemoved: (() -> Void)? = nil) -> some View {
        confirmationDialog("Remove friend?", isPresented: Binding(get: { removing.wrappedValue != nil }, set: { if !$0 { removing.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: removing.wrappedValue) { profile in
            Button("Remove \(profile.label)", role: .destructive) {
                Task { await model.remove(profile); onRemoved?() }
            }
        } message: { profile in
            Text("You and \(profile.label) will stop seeing each other’s listening activity. You can send a new request later.")
        }
    }
}
