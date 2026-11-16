import SwiftUI

struct Tracks: View {
    @Environment(LibraryStore.self) private var library
    @AppStorage("library.sort.tracks") private var sort = "Title"
    @State private var query = ""
    private var sorted: [LibraryTrack] {
        LibrarySortMenu.tracks(library.tracks.filter { query.isEmpty || "\($0.title) \($0.artist) \($0.album)".localizedStandardContains(query) }, by: sort)
    }
    var body: some View {
        let visible = sorted
        List {
            if !visible.isEmpty { Section { LibraryPlayButtons(tracks: visible) } }
            ForEach(visible) { track in LibraryTrackRow(track: track, queue: visible) }
        }
        .overlay { if library.tracks.isEmpty { ContentUnavailableView("No Tracks Yet", systemImage: "music.note", description: Text("Import music to see your tracks here.")) } }
        .navigationTitle("Tracks")
        .searchable(text: $query, prompt: "Find a track")
        .toolbar { LibrarySortMenu(selection: $sort); MusicButton().labelStyle(.iconOnly) }
    }
}
