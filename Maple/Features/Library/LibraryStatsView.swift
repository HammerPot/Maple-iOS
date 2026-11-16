import SwiftUI
import Charts

/// Totals and top tracks/artists/albums from the per-track statistics the player records.
struct LibraryStatsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions

    private struct Ranked<Item: Identifiable>: Identifiable {
        let item: Item
        let plays: Int
        let seconds: Double
        var id: Item.ID { item.id }
    }

    var body: some View {
        let stats = library.statistics
        let totals = stats.values.reduce(into: TrackStatistics()) {
            $0.plays += $1.plays; $0.completions += $1.completions; $0.skips += $1.skips; $0.listeningSeconds += $1.listeningSeconds
        }
        let topTracks = rank(library.tracks) { [$0.id] }
        List {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    StatTile(title: "Plays", value: totals.plays.formatted(), systemImage: "play.circle")
                    StatTile(title: "Listening Time", value: Self.listening(totals.listeningSeconds), systemImage: "clock")
                    StatTile(title: "Played to the End", value: totals.completions.formatted(), systemImage: "checkmark.circle")
                    StatTile(title: "Skipped", value: totals.skips.formatted(), systemImage: "forward.end")
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            }
            if topTracks.isEmpty {
                Section {
                    ContentUnavailableView("Your Listening Starts Here", systemImage: "chart.bar",
                                           description: Text("Play music from your library to see your favourites and listening time."))
                }
                .listRowBackground(Color.clear)
            } else {
                Section("Top Tracks") {
                    Chart(topTracks.prefix(5)) { entry in
                        BarMark(x: .value("Plays", entry.plays), y: .value("Track", entry.item.title))
                            .annotation(position: .trailing) { Text(entry.plays.formatted()).font(.caption).foregroundStyle(.secondary) }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(min(topTracks.count, 5)) * 36)
                    .accessibilityLabel("Top tracks by plays")
                    ForEach(topTracks.prefix(10)) { entry in
                        LibraryTrackRow(track: entry.item, queue: topTracks.prefix(10).map(\.item), trailing: Self.plays(entry.plays))
                    }
                }
                Section("Top Artists") {
                    ForEach(rank(library.artists) { $0.trackIDs }.prefix(5)) { entry in
                        NavigationLink(value: LibraryRoute.artist(entry.item.id)) {
                            LabeledContent(entry.item.name, value: Self.plays(entry.plays))
                        }
                    }
                }
                Section("Top Albums") {
                    ForEach(rank(library.albums) { $0.trackIDs }.prefix(5)) { entry in
                        NavigationLink(value: LibraryRoute.album(entry.item.id)) {
                            HStack(spacing: 12) {
                                LibraryArtwork(reference: entry.item.artwork, size: 44).frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.item.name).lineLimit(1)
                                    Text(entry.item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(Self.plays(entry.plays)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            if !library.recentIDs.isEmpty {
                Section {
                    Button("Clear Recently Played", role: .destructive) { actions.clearRecentlyPlayed() }
                } footer: {
                    Text("Statistics are kept. Deleting a track removes its statistics; clearing the library removes all of them.")
                }
            }
        }
        .navigationTitle("Listening Stats")
    }

    private func rank<Item: Identifiable>(_ items: [Item], ids: (Item) -> [UUID]) -> [Ranked<Item>] {
        items.compactMap { item -> Ranked<Item>? in
            let stats = ids(item).map { library.statistics(for: $0) }
            let plays = stats.reduce(0) { $0 + $1.plays }
            return plays > 0 ? Ranked(item: item, plays: plays, seconds: stats.reduce(0) { $0 + $1.listeningSeconds }) : nil
        }
        .sorted { $0.plays == $1.plays ? $0.seconds > $1.seconds : $0.plays > $1.plays }
    }

    static func plays(_ count: Int) -> String { count == 1 ? "1 play" : "\(count.formatted()) plays" }

    static func listening(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
