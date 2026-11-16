import SwiftUI
import PhotosUI

/// Signed-in root of the Account tab: profile, own listening, visibility, security and sign-out.
struct AccountHomeView: View {
    let user: MapleUser
    @Environment(AppServices.self) private var services
    @Environment(AuthSessionModel.self) private var auth
    @Environment(ToastCenter.self) private var toasts
    @State private var model: ProfileModel
    @State private var photo: PhotosPickerItem?
    @State private var listeningReceivedAt = Date()
    @State private var confirmsSignOut = false
    @State private var isSigningOut = false

    init(user: MapleUser, api: any AccountProfileService, session: any AccountSecurityService) {
        self.user = user
        _model = State(initialValue: ProfileModel(api: api, session: session))
    }

    var body: some View {
        List {
            Section {
                ProfileHeader(user: user, photo: $photo, isUploading: model.isUploadingPhoto)
            }
            .listRowBackground(Color.clear)
            listeningSection
            profileSection
            Section {
                NavigationLink {
                    SecurityView(session: auth)
                } label: {
                    Label("Password & Security", systemImage: "lock.shield")
                }
            }
            Section {
                Button(role: .destructive) { confirmsSignOut = true } label: {
                    BusyButtonLabel(title: "Sign Out", busy: isSigningOut)
                }
                .disabled(isSigningOut)
            }
        }
        .navigationTitle("Account")
        .onChange(of: user.listening) { listeningReceivedAt = .now }
        .onChange(of: user.listeningVisibility) { model.syncFromUser() }
        .onChange(of: photo) { _, item in upload(item) }
        .refreshable { try? await auth.refresh() }
        .confirmationDialog("Sign out of Maple on this device?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await signOut() } }
        }
        .alert("Couldn’t Update Your Profile", isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .passkeyPrompt(userID: user.id, session: auth)
    }

    private var listeningSection: some View {
        Section {
            ListeningCard(userID: user.id, status: ListeningStatus(user.listening), receivedAt: listeningReceivedAt)
                .padding(.vertical, 6)
            Toggle(isOn: sharesBinding) {
                Label("Share with Friends", systemImage: "person.2.wave.2")
            }
            .disabled(model.isSavingVisibility)
        } header: {
            Text("Listening")
        } footer: {
            Text(model.sharesListening
                 ? "Friends can see what you’re playing right now and the last thing you played."
                 : "Friends can’t see what you’re playing or what you played last.")
        }
    }

    private var profileSection: some View {
        Section("Profile") {
            NavigationLink {
                EditDisplayNameView(current: user.name ?? "", model: model)
            } label: {
                LabeledContent("Display Name", value: displayName)
            }
            LabeledContent("Username", value: "@" + user.username)
                .accessibilityHint("Usernames can’t be changed.")
            PhotosPicker(selection: $photo, matching: .images, photoLibrary: .shared()) {
                Label("Change Profile Photo", systemImage: "photo.on.rectangle")
            }
            .disabled(model.isUploadingPhoto)
        }
    }

    private var displayName: String {
        if let name = user.name, !name.isEmpty { return name }
        return "Not Set"
    }
    private var sharesBinding: Binding<Bool> {
        Binding(get: { model.sharesListening }, set: { value in Task { await model.setSharesListening(value) } })
    }
    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
    }
    private func upload(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            await model.uploadPhoto(data)
            photo = nil
        }
    }

    private func signOut() async {
        isSigningOut = true; defer { isSigningOut = false }
        do { try await auth.signOut() }
        catch {
            // The person asked to sign out: clear this device either way, and say if the server wasn't reached.
            await auth.invalidate()
            if !AccountErrorCopy.endsSession(error) {
                toasts.show("Signed out on this device. Maple couldn’t be reached, so that session will expire on its own.")
            }
        }
    }
}

private struct ProfileHeader: View {
    let user: MapleUser
    @Binding var photo: PhotosPickerItem?
    let isUploading: Bool
    @ScaledMetric private var avatarSize = 96

    var body: some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $photo, matching: .images, photoLibrary: .shared()) {
                AvatarView(userID: user.id, data: user.pfp)
                    .id(user.pfp)
                    .frame(width: avatarSize, height: avatarSize)
                    .overlay {
                        if isUploading {
                            Circle().fill(.ultraThinMaterial)
                            ProgressView()
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.title2)
                            .background(Circle().fill(.background))
                    }
            }
            .buttonStyle(.plain)
            .disabled(isUploading)
            .accessibilityLabel("Profile photo")
            .accessibilityHint("Choose a new photo")
            .accessibilityValue(isUploading ? "Uploading" : "")

            VStack(spacing: 2) {
                Text(user.profile.label).font(.title2.bold())
                Text("@" + user.username).font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
    }
}
