import SwiftUI
import UniformTypeIdentifiers

struct MusicButton: View {
    var body: some View { MusicImportButton(iconOnly: false) }
}

struct MusicButtonPlus: View {
    var body: some View { MusicImportButton(iconOnly: true) }
}

struct MusicImportButton: View {
    let iconOnly: Bool
    @ObservedObject private var importer = MusicLibraryImporter.shared

    var body: some View {
        Button {
            importer.presentingImporter = true
        } label: {
            if iconOnly {
                Label("Add Music", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                Label(importer.isImporting ? "Importing Music…" : "Add Music", systemImage: "plus")
            }
        }
        .disabled(importer.isImporting)

    }
}

@MainActor
func clearDocumentsDirectory() {
    AudioPlayerManager.shared.clearQueue()
    // Restrict removal to folders owned by the music library.
    for folder in ["tracks", "images", "albums", "artists", "playlists"] {
        let url = MapleLibrary.directory.appending(path: folder)
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { MusicLibraryImporter.shared.errorMessage = error.localizedDescription }
        }
    }
    NotificationCenter.default.post(name: MapleLibrary.changed, object: nil)
}
