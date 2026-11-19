import SwiftUI

struct SessionsView: View {
    @Environment(ToastCenter.self) private var toasts
    @State private var model: SessionsModel
    @State private var confirmsEverywhere = false
    @State private var pendingRevoke: SessionsModel.Row?

    init(session: any AccountSecurityService) { _model = State(initialValue: SessionsModel(session: session)) }

    var body: some View {
        List {
            if let current = model.current {
                Section("This Device") { SessionRow(row: current, busy: false) }
            }
            if !model.others.isEmpty {
                Section {
                    ForEach(model.others) { row in
                        SessionRow(row: row, busy: model.revoking.contains(row.id))
                            .swipeActions {
                                Button("Sign Out", role: .destructive) { pendingRevoke = row }
                            }
                            .contextMenu {
                                Button("Sign Out This Device", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { pendingRevoke = row }
                            }
                            .accessibilityAction(named: "Sign Out This Device") { pendingRevoke = row }
                    }
                } header: {
                    Text("Other Devices")
                } footer: {
                    Text("Swipe left on a device to sign it out.")
                }
            } else if model.hasLoaded {
                Section {
                    Text("You’re not signed in anywhere else.").foregroundStyle(.secondary)
                }
            }
            if model.hasLoaded {
                Section {
                    Button(role: .destructive) { confirmsEverywhere = true } label: {
                        BusyButtonLabel(title: "Sign Out Everywhere", busy: model.isSigningOutEverywhere)
                    }
                    .disabled(model.isSigningOutEverywhere)
                } footer: {
                    Text("Signs out every device, including this one.")
                }
            }
        }
        .overlay {
            if !model.hasLoaded {
                if let error = model.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn’t Load Devices", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Try Again") { Task { await model.load() } }
                    }
                } else {
                    ProgressView()
                }
            }
        }
        .accountFormKeyboard()
        .navigationTitle("Signed-In Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.report = { toasts.show($0) }
            await model.load()
        }
        .refreshable { await model.load() }
        .confirmationDialog("Sign out everywhere?", isPresented: $confirmsEverywhere, titleVisibility: .visible) {
            Button("Sign Out Everywhere", role: .destructive) { Task { await model.signOutEverywhere() } }
        } message: {
            Text("Every device signed in to your Maple account, including this one, will need to sign in again.")
        }
        .confirmationDialog("Sign out this device?", isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
                            titleVisibility: .visible, presenting: pendingRevoke) { row in
            Button("Sign Out \(row.device.title)", role: .destructive) { Task { await model.revoke(row) } }
        } message: { _ in
            Text("It will need to sign in again to use your account.")
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { model.hasLoaded && model.errorMessage != nil },
                                                          set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }
}

private struct SessionRow: View {
    let row: SessionsModel.Row
    let busy: Bool
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: row.device.systemImage)
                .font(.title2).foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.device.title).font(.headline)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(row.isCurrent ? "Active now" : "Last active \(MapleFormat.relative(row.lastActive, to: context.date))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Signed in \(row.signedInAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote).foregroundStyle(.secondary)
                if let ip = row.ipAddress, !ip.isEmpty {
                    Text(ip).font(.footnote.monospaced()).foregroundStyle(.secondary).privacySensitive()
                }
            }
            Spacer(minLength: 0)
            if busy { ProgressView() }
        }
        .accessibilityElement(children: .combine)
    }
}
