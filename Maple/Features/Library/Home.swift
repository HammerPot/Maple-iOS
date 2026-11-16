import SwiftUI

struct Home: View {
    @State private var showingSettings = false

    var body: some View {
        LibraryNavigationStack {
            HomeContent()
                .navigationTitle("Home")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    }
                    ToolbarItem(placement: .primaryAction) { MusicButton() }
                }
                .sheet(isPresented: $showingSettings) {
                    NavigationStack {
                        Settings()
                            .navigationTitle("Settings")
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } }
                            }
                    }
                }
        }
    }
}

private struct HomeContent: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @ObservedObject private var appleMusic = AppleMusicManager.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if !library.isLoaded {
            if let error = library.loadError {
                ContentUnavailableView {
                    Label("Couldn’t Open Your Library", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await library.load() } }.buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("Opening your library…")
            }
        } else if library.tracks.isEmpty {
            ScrollView {
                VStack(spacing: 24) {
                    ContentUnavailableView {
                        Label("Welcome to Maple", systemImage: "music.note.house")
                    } description: {
                        Text("Add your own audio files to build your library. Your music stays on this device.")
                    } actions: {
                        MusicButton(style: .prominent)
                    }
                    Text("You can also copy music into Maple’s folder in the Files app. New files are picked up whenever you open Maple.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    if appleMusic.authStatus == .authorized { appleMusicLink.padding(.horizontal) }
                }
                .padding(.vertical, 32)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    shortcuts
                    if !library.recentlyPlayed.isEmpty {
                        shelf("Recently Played", tracks: Array(library.recentlyPlayed.prefix(20))) {
                            Button("Clear") { actions.clearRecentlyPlayed() }
                                .font(.subheadline)
                                .accessibilityLabel("Clear Recently Played")
                        }
                    }
                    shelf("Recently Added", tracks: Array(library.recentlyAdded.prefix(20))) { EmptyView() }
                    if appleMusic.authStatus == .authorized { appleMusicLink.padding(.horizontal) }
                }
                .padding(.vertical)
            }
        }
    }

    private var shortcuts: some View {
        // One column at accessibility text sizes so labels never break mid-word.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 320 : 150), spacing: 10)], spacing: 10) {
            HomeShortcut(title: "Shuffle All", systemImage: "shuffle") { LibraryPlayback.play(library.tracks, shuffle: true) }
            HomeShortcut(title: "Playlists", systemImage: "music.note.list", route: .playlists)
            HomeShortcut(title: "Albums", systemImage: "square.stack", route: .albums)
            HomeShortcut(title: "Listening Stats", systemImage: "chart.bar", route: .stats)
        }
        .padding(.horizontal)
    }

    private func shelf<Accessory: View>(_ title: String, tracks: [LibraryTrack], @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                accessory()
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(tracks) { track in HomeTrackCard(track: track, queue: tracks) }
                }
                .padding(.horizontal)
            }
        }
    }

    private var appleMusicLink: some View {
        NavigationLink(value: LibraryRoute.appleMusic) {
            Label("Apple Music", systemImage: "applelogo")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct HomeShortcut: View {
    @Environment(\.openLibraryRoute) private var open
    let title: String
    let systemImage: String
    var route: LibraryRoute?
    var action: (() -> Void)?

    init(title: String, systemImage: String, route: LibraryRoute) {
        self.title = title; self.systemImage = systemImage; self.route = route
    }
    init(title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.action = action
    }

    var body: some View {
        Button {
            if let route { open(route) } else { action?() }
        } label: {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(.tint)
            }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct HomeTrackCard: View {
    @Environment(LibraryActions.self) private var actions
    let track: LibraryTrack
    let queue: [LibraryTrack]
    var body: some View {
        Button { LibraryPlayback.play(queue, startingAt: track.id) } label: {
            LibraryCard(title: track.title, subtitle: track.artist, artwork: track.artwork)
                .frame(width: 150)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays this track")
        .contextMenu {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { LibraryPlayback.enqueue([track], next: true) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { LibraryPlayback.enqueue([track], next: false) }
            Button("Add to Playlist…", systemImage: "text.badge.plus") { actions.addToPlaylist([track.id]) }
            Button("Delete from Library", systemImage: "trash", role: .destructive) { actions.delete(track: track) }
        }
    }
}
