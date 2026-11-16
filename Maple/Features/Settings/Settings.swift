import SwiftUI

struct Settings: View {
    @Environment(AppServices.self) private var services
    @Environment(LibraryStore.self) private var library
    @Environment(AppleMusicService.self) private var music
    @Environment(SettingsModel.self) private var settings
    @Environment(ToastCenter.self) private var toasts
    @Environment(LibraryActions.self) private var actions
    @AppStorage("mapleRPC") private var mapleRPC = false
    @AppStorage("socketIO") private var socketIO = true
    @AppStorage("musicKit") private var musicKit = false
    @State private var clearConfirmation = false
    @State private var showingImport = false
    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Toggle("Share Listening Activity with Friends", isOn: $socketIO)
                    .onChange(of: socketIO) { _, _ in services.syncSocket() }
                Toggle("Discord Rich Presence", isOn: $mapleRPC)
                    .onChange(of: mapleRPC) { _, _ in Task { await services.playback.sendUpdate() } }
                SecureField("Discord Webhook URL", text: $settings.webhookURL)
                    .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(saveWebhook)
                Button("Save Webhook", action: saveWebhook).disabled(settings.isSaving || !settings.isLoaded)
            } header: { Text("Sharing") } footer: {
                Text("Friends and Discord Rich Presence require a Maple account and listening activity sharing. The optional Discord webhook is stored securely on this device; leave it blank to disable it.")
            }
            Section {
                Toggle("Apple Music", isOn: $musicKit)
                    .onChange(of: musicKit) { _, enabled in
                        if !enabled && services.player.currentItem?.source == .appleMusic { services.player.stop() }
                        Task { await music.refreshAuthorization(request: enabled) }
                    }
                LabeledContent("Library Access", value: music.authorizationLabel)
                if musicKit { NavigationLink("Browse Apple Music") { AppleMusic() } }
            } header: { Text("Apple Music") } footer: {
                Text("Catalog playback requires an Apple Music subscription. Music continues in the system Music app when you switch apps.")
            }
            Section("Library") {
                MusicButton()
                Button("Scan for New Files", systemImage: "arrow.clockwise") { library.scanForNewFiles(); showingImport = true }
                    .disabled(library.progress != nil || !library.isLoaded)
                NavigationLink("Listening Stats") { LibraryStatsView() }
                Button("Clear Recently Played") { actions.clearRecentlyPlayed() }
                Button("Clear Library…", systemImage: "trash", role: .destructive) { clearConfirmation = true }
                    .disabled(library.progress != nil || !library.isLoaded)
                NavigationLink("Acknowledgements") { LibraryAcknowledgements() }
            }
            Section("About") {
                LabeledContent("Version", value: Self.version)
                SettingsLink(title: "Maple for iOS on GitHub", address: "https://github.com/HammerPot/Maple-iOS")
                SettingsLink(title: "Maple on GitHub", address: "https://github.com/cattn/maple")
                SettingsLink(title: "maple.music", address: "https://maple.music")
                SettingsLink(title: "Privacy Policy", address: "https://maple.music/privacy")
                Text("Maple originally made by Cattn.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task { do { try await settings.load() } catch { toasts.show(error) } }
        .sheet(isPresented: $showingImport) { LibraryImportSheet() }
        .alert("Clear Library?", isPresented: $clearConfirmation) {
            Button("Delete Library", role: .destructive, action: clearLibrary)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All imported music, artwork, playlists, lyrics, recently played and listening statistics will be permanently deleted from this device. Your account and settings are kept.")
        }
    }
    private static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
    private func saveWebhook() {
        Task { do { try await settings.saveWebhook(); toasts.show("Webhook saved") } catch { toasts.show(error) } }
    }
    private func clearLibrary() {
        Task { do { try await library.clearLibrary() } catch { toasts.show(error) } }
    }
}
private struct SettingsLink: View {
    let title: String
    let address: String
    var body: some View { if let url = URL(string: address) { Link(title, destination: url) } }
}
