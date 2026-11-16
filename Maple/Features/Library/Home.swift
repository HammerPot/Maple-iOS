import SwiftUI

struct Home: View {
    @Environment(LibraryStore.self) private var library
    @ObservedObject private var manager = AppleMusicManager.shared
    @State private var settings = false
    @State private var clearingRecent = false
    var body: some View {
        NavigationStack {
            List {
                if !library.isLoaded {
                    Section {
                        if let error = library.errorMessage {
                            ContentUnavailableView("Could Not Open Library", systemImage: "exclamationmark.triangle", description: Text(error))
                            Button("Try Again") { Task { await library.load() } }
                        } else { ProgressView("Opening your library…") }
                    }
                } else if library.tracks.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("Your Music, at Home", systemImage: "music.note.house")
                        } description: {
                            Text("Import your audio files to start your own library. Your music stays on this device.")
                        } actions: { MusicButton() }
                    }
                } else {
                    if !library.recentlyPlayed.isEmpty {
                        Section {
                            ForEach(library.recentlyPlayed.prefix(6)) { track in LibraryTrackRow(track: track, queue: library.recentlyPlayed) }
                        } header: {
                            HStack {
                                Text("Recently Played")
                                Spacer()
                                Button("Clear") { clearingRecent = true }.font(.caption)
                            }
                        }
                    }
                    Section("Recently Added") {
                        ForEach(library.recentlyAdded.prefix(6)) { track in LibraryTrackRow(track: track, queue: library.recentlyAdded) }
                    }
                }
                Section("Explore Your Library") {
                    NavigationLink { Tracks() } label: { Label("Tracks", systemImage: "music.note.list") }
                    NavigationLink { Albums() } label: { Label("Albums", systemImage: "square.stack") }
                    NavigationLink { Artists() } label: { Label("Artists", systemImage: "music.mic") }
                    NavigationLink { Playlists() } label: { Label("Playlists", systemImage: "text.badge.plus") }
                    NavigationLink { LibraryStatsView() } label: { Label("Listening Stats", systemImage: "chart.bar") }
                }
                if manager.authStatus == .authorized {
                    Section { NavigationLink("Apple Music") { AppleMusic() } }
                }
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { MusicButton().labelStyle(.iconOnly) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { settings = true }.labelStyle(.iconOnly)
                }
            }
            .sheet(isPresented: $settings) {
                NavigationStack { Settings().navigationTitle("Settings").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } } }
            }
            .confirmationDialog("Clear recently played?", isPresented: $clearingRecent, titleVisibility: .visible) {
                Button("Clear Recently Played", role: .destructive) { library.clearRecentlyPlayed() }
            } message: { Text("This removes the recently played list. Your music and listening statistics are kept.") }
        }
    }
}
