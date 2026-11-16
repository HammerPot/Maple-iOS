import SwiftUI
import Charts

struct LibraryStatsView: View {
    @Environment(LibraryStore.self) private var library
    private var topTracks: [LibraryTrack] {
        library.tracks.filter { library.statistics[$0.id, default: TrackStatistics()].plays > 0 }
            .sorted { library.statistics[$0.id, default: TrackStatistics()].plays > library.statistics[$1.id, default: TrackStatistics()].plays }
    }
    private var totalPlays: Int { library.statistics.values.reduce(0) { $0 + $1.plays } }
    private var listening: Double { library.statistics.values.reduce(0) { $0 + $1.listeningSeconds } }
    private func plays(_ ids: [UUID]) -> Int { ids.reduce(0) { $0 + library.statistics[$1, default: TrackStatistics()].plays } }
    var body: some View {
        List {
            Section("Your Listening") {
                LabeledContent("Plays", value: totalPlays.formatted())
                LabeledContent("Listening Time", value: Duration.seconds(listening).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
                LabeledContent("Completions", value: library.statistics.values.reduce(0) { $0 + $1.completions }.formatted())
                LabeledContent("Skips", value: library.statistics.values.reduce(0) { $0 + $1.skips }.formatted())
            }
            if !topTracks.isEmpty {
                Section("Top Tracks") {
                    Chart(Array(topTracks.prefix(5))) { track in
                        BarMark(x: .value("Plays", library.statistics[track.id, default: TrackStatistics()].plays), y: .value("Track", track.title))
                    }.frame(height: 180)
                    ForEach(topTracks.prefix(10)) { track in
                        HStack { LibraryTrackRow(track: track); Text("\(library.statistics[track.id, default: TrackStatistics()].plays)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section("Top Artists") {
                    ForEach(library.artists.filter { plays($0.trackIDs) > 0 }.sorted { plays($0.trackIDs) > plays($1.trackIDs) }.prefix(10)) { artist in
                        NavigationLink { ArtistDetailView(artist: artist) } label: { LabeledContent(artist.name, value: "\(plays(artist.trackIDs)) plays") }
                    }
                }
                Section("Top Albums") {
                    ForEach(library.albums.filter { plays($0.trackIDs) > 0 }.sorted { plays($0.trackIDs) > plays($1.trackIDs) }.prefix(10)) { album in
                        NavigationLink { AlbumDetailView(album: album) } label: { LabeledContent(album.name, value: "\(plays(album.trackIDs)) plays") }
                    }
                }
            } else {
                Section { ContentUnavailableView("Your Listening Starts Here", systemImage: "chart.bar", description: Text("Play music from your library to see your favourites and listening time.")) }
            }
        }.navigationTitle("Listening Stats")
    }
}
