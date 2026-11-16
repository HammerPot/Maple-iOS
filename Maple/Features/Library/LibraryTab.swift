import SwiftUI

struct LibraryTab: View {
    @Environment(LibraryStore.self) private var library
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { Tracks() } label: { Label("Tracks · \(library.tracks.count)", systemImage: "music.note.list") }
                    NavigationLink { Albums() } label: { Label("Albums · \(library.albums.count)", systemImage: "square.stack") }
                    NavigationLink { Artists() } label: { Label("Artists · \(library.artists.count)", systemImage: "music.mic") }
                    NavigationLink { Playlists() } label: { Label("Playlists · \(library.playlists.count)", systemImage: "text.badge.plus") }
                }
                Section { NavigationLink { LibraryStatsView() } label: { Label("Listening Stats", systemImage: "chart.bar") } }
                if library.tracks.isEmpty {
                    Section {
                        ContentUnavailableView("Make It Yours", systemImage: "music.note", description: Text("Add files or a folder of music to build your library."))
                        MusicButton()
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar { MusicButton().labelStyle(.iconOnly) }
        }
    }
}
