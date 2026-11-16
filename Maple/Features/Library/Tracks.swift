import SwiftUI

struct Tracks: View {
    @Environment(LibraryStore.self) private var library
    private var sort = LibrarySortState("tracks", default: TrackSort.title)
    @State private var query = ""

    private var visible: [LibraryTrack] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = term.isEmpty ? library.tracks : library.tracks.filter {
            $0.title.localizedStandardContains(term) || $0.artist.localizedStandardContains(term) || $0.album.localizedStandardContains(term)
        }
        return sort.apply(matches)
    }

    var body: some View {
        let tracks = visible
        List {
            if !tracks.isEmpty {
                Section {
                    LibraryPlayButtons(tracks: tracks)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                Section {
                    ForEach(tracks) { track in LibraryTrackRow(track: track, queue: tracks) }
                } footer: {
                    Text(LibraryText.summary(tracks: tracks.count, duration: tracks.reduce(0) { $0 + $1.duration }))
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if library.tracks.isEmpty {
                ContentUnavailableView {
                    Label("No Tracks Yet", systemImage: "music.note")
                } description: {
                    Text("Add audio files to see your tracks here.")
                } actions: { MusicButton(style: .prominent) }
            } else if tracks.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Tracks")
        .searchable(text: $query, prompt: "Filter tracks")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                LibrarySortMenu(state: sort, options: TrackSort.library)
                MusicButton()
            }
        }
    }
}
