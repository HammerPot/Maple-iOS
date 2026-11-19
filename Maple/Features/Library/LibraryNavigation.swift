import SwiftUI

/// Every library screen reachable by push. Value-based so destinations are built lazily and
/// any screen (or context menu) can open an album, artist or playlist.
enum LibraryRoute: Hashable {
    case tracks, albums, artists, playlists, stats, acknowledgements
    case album(String)
    case artist(String)
    case playlist(UUID)
    case appleMusic
}

struct OpenLibraryRouteAction {
    fileprivate let handler: (LibraryRoute) -> Void
    func callAsFunction(_ route: LibraryRoute) { handler(route) }
}

extension EnvironmentValues {
    @Entry var openLibraryRoute = OpenLibraryRouteAction { _ in }
}

/// A tab's navigation stack with the library destinations registered.
struct LibraryNavigationStack<Root: View>: View {
    @State private var path = NavigationPath()
    @ViewBuilder var root: Root
    var body: some View {
        NavigationStack(path: $path) {
            root.navigationDestination(for: LibraryRoute.self) { route in
                LibraryDestination(route: route)
            }
        }
        .environment(\.openLibraryRoute, OpenLibraryRouteAction { path.append($0) })
    }
}

private struct LibraryDestination: View {
    let route: LibraryRoute
    var body: some View {
        switch route {
        case .tracks: Tracks()
        case .albums: Albums()
        case .artists: Artists()
        case .playlists: Playlists()
        case .stats: LibraryStatsView()
        case .acknowledgements: LibraryAcknowledgements()
        case .album(let id): AlbumDetailView(albumID: id)
        case .artist(let id): ArtistDetailView(artistID: id)
        case .playlist(let id): PlaylistDetailView(playlistID: id)
        case .appleMusic: AppleMusic()
        }
    }
}
