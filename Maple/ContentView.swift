import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var socketManager = AppSocketManager.shared
    @ObservedObject private var amPlayer = AMPlayer.shared
    @State private var showPlayer = false
    @ObservedObject private var importer = MusicLibraryImporter.shared

    var body: some View {
        tabs
            .snackbarView(snackbar: $socketManager.snackbar)
            .fileImporter(isPresented: $importer.presentingImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let files): importer.importFiles(files)
                case .failure(let error): importer.errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showPlayer) {
                NowPlayingSheet()
            }
            .alert("Unable to play Apple Music", isPresented: Binding(
                get: { amPlayer.errorMessage != nil },
                set: { if !$0 { amPlayer.errorMessage = nil } }
            )) {} message: {
                Text(amPlayer.errorMessage ?? "")
            }
            .alert("Unable to update music library", isPresented: Binding(
                get: { importer.errorMessage != nil },
                set: { if !$0 { importer.errorMessage = nil } }
            )) {} message: {
                Text(importer.errorMessage ?? "")
            }
            .task {
                do {
                    try await MapleLibrary.prepare()
                    NotificationCenter.default.post(name: MapleLibrary.changed, object: nil)
                } catch {
                    importer.errorMessage = error.localizedDescription
                }
                let images = MapleLibrary.directory.appending(path: "images")
                try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
                try? PlatformImage(named: "Maple")?.pngData()?.write(to: images.appending(path: "maple.image"))
                if UserDefaults.standard.bool(forKey: "musicKit") {
                    AppleMusicManager.shared.checkAuthorization()
                }
            }
    }

    private var tabs: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                MainTabContent(showPlayer: $showPlayer) { Home() }
            }
            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                MainTabContent(showPlayer: $showPlayer) { Search() }
            }
            Tab("Account", systemImage: "person.crop.circle") {
                MainTabContent(showPlayer: $showPlayer) {
                    NavigationStack { Login().navigationTitle("Account") }
                }
            }
            Tab("Settings", systemImage: "gear") {
                MainTabContent(showPlayer: $showPlayer) {
                    NavigationStack { Settings().navigationTitle("Settings") }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
