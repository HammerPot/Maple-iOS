import SwiftUI
import MusicKit

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @Environment(FriendsModel.self) private var friends
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PlaybackController.self) private var player
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
            LibraryNavigationStack { FullPlayer() }.libraryActionPresenter()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: library.scanForNewFiles(silently: true) // pick up files added in the Files app
            case .background:
                player.sample(); player.save()
                Task { do { try await library.flush() } catch { toasts.show(error) } }
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
