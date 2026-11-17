import SwiftUI
import MusicKit

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @Environment(FriendsModel.self) private var friends
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var audioManager = AudioPlayerManager.shared
    @ObservedObject private var amPlayer = AMPlayer.shared
    @State private var showPlayer = false

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                tabs.tabViewBottomAccessory { NowPlayingBar(showPlayer: $showPlayer) }
            } else {
                tabs.safeAreaInset(edge: .bottom, spacing: 0) {
                    NowPlayingBar(showPlayer: $showPlayer).background(.bar)
                }
            }
        }
        .sheet(isPresented: $showPlayer) {
            if amPlayer.initialized { AMPlayerView2() }
            else if let song = audioManager.currentSong { MediaPlayerView(song: song, allSongs: audioManager.queue) }
            else { ContentUnavailableView("Nothing Playing", systemImage: "music.note") }
        }
        .task {
            if UserDefaults.standard.bool(forKey: "musicKit") { AppleMusicManager.shared.checkAuthorization() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: library.scanForNewFiles(silently: true) // pick up files added in the Files app
            case .background: Task { do { try await library.flushIfLoaded() } catch { toasts.show(error) } }
            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearMapleLibrary)) { _ in
            Task { do { try await library.clearLibrary() } catch { toasts.show(error) } }
        }
        .onChange(of: library.errorMessage) { _, message in
            if let message { toasts.show(message); library.errorMessage = nil }
        }
        .onChange(of: library.announcement) { _, message in
            if let message { toasts.show(message); library.announcement = nil }
        }
        .libraryActionPresenter()
    }
    private var tabs: some View {
        TabView {
            Tab("Home", systemImage: "house") { Home() }
            Tab("Library", systemImage: "music.note.list") { LibraryTab() }
            Tab("Friends", systemImage: "person.2") { FriendsTab() }
                .badge(friends.requests.incoming.count)
            Tab("Account", systemImage: "person.crop.circle") { AccountTab() }
            Tab("Search", systemImage: "magnifyingglass", role: .search) { Search() }
        }
    }
}

struct NowPlayingBar: View {
    @ObservedObject private var audioManager = AudioPlayerManager.shared
    @ObservedObject private var amPlayer = AMPlayer.shared
    @Binding var showPlayer: Bool

    var body: some View {

        if amPlayer.initialized == true{
            ZStack {
                    NavigationLink(
                        destination: AMPlayerView2(),
                        isActive: $showPlayer
                    ) { EmptyView() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    HStack(spacing: 12) {
                        Group {
                            if let artwork = amPlayer.albumArt {
                                Image(uiImage: artwork)
                                        .resizable()
                                        .frame(width: 30, height: 30)

                            } else if let uiImage = UIImage(named: "Maple") {
                                Image(uiImage: uiImage)
                                    .resizable()
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxHeight: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            if let currentEntry = SystemMusicPlayer.shared.queue.currentEntry,
                               case .song(let song) = currentEntry.item {
                                Text(song.title)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text(song.artistName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text("No song playing")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text("Artist")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .layoutPriority(1)
                        Spacer(minLength: 8)
                        HStack(spacing: 12) {
                            Button(action: {
                                Task {
                                    if SystemMusicPlayer.shared.state.playbackStatus == .playing {
                                        SystemMusicPlayer.shared.pause()
                                    } else {
                                        try? await SystemMusicPlayer.shared.play()
                                    }
                                }
                            }) {
                                Image(systemName: amPlayer.isPlaying == true ? "pause.fill" : "play.fill")
                                    .font(.title3)
                            }
                            .buttonStyle(.borderless)

                            Button(action: {
                                Task {
                                    try? await SystemMusicPlayer.shared.skipToNextEntry()
                                }
                            }) {
                                Image(systemName: "forward.fill")
                                    .font(.title3)
                            }
                            .buttonStyle(.borderless)
                            Button(action: {
                                UIApplication.shared.open(URL(string: "music://")!, options: [:], completionHandler: nil)
                            }){
                                Image(uiImage: UIImage(named: "AM")!)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: 56, alignment: .center)
                }
                .onTapGesture {
                    showPlayer = true
                }
        } else {
            ZStack {
                NavigationLink(
                    destination: MediaPlayerView(song: audioManager.currentSong ?? Song(fileName: "", title: "No Song"), allSongs: audioManager.queue),
                    isActive: $showPlayer
                ) { EmptyView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                HStack(spacing: 12) {
                    Group {
                        if let currentSong = audioManager.currentSong,
                        let artwork = currentSong.artwork,
                        let uiImage = UIImage(contentsOfFile: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(artwork).path) {
                            Image(uiImage: uiImage)
                                .resizable()
                        } else if let uiImage = UIImage(named: "Maple") {
                            Image(uiImage: uiImage)
                                .resizable()
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxHeight: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(audioManager.currentSong?.title ?? "No song playing")
                            .font(.caption)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(audioManager.currentSong?.artist ?? "Artist")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    HStack(spacing: 12) {
                        Button(action: {
                            if audioManager.isPlaying {
                                audioManager.pause()
                            } else {
                                audioManager.play()
                            }
                        }) {
                            Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)

                        Button(action: {
                            audioManager.playNext()
                        }) {
                            Image(systemName: "forward.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: 56, alignment: .center)
            }
            .onTapGesture {
                showPlayer = true
            }
        }
    }
}
