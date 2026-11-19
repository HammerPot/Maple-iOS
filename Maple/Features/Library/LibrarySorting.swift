import SwiftUI

/// A sort key for one kind of library item. Each screen stores its own choice under its own
/// `AppStorage` key, so sorting Albums by Year never changes how Artists are sorted.
protocol LibrarySortKey: RawRepresentable, CaseIterable, Hashable where RawValue == String, AllCases: RandomAccessCollection {
    associatedtype Item
    var title: String { get }
    /// Whether the natural direction for this key is descending (newest, longest first).
    var defaultDescending: Bool { get }
    func ascending(_ lhs: Item, _ rhs: Item) -> Bool
}

extension LibrarySortKey {
    var defaultDescending: Bool { false }
    func sorted(_ items: [Item], descending: Bool) -> [Item] {
        items.sorted { descending ? ascending($1, $0) : ascending($0, $1) }
    }
}

private func ordered(_ lhs: String, _ rhs: String) -> Bool { lhs.localizedStandardCompare(rhs) == .orderedAscending }

enum TrackSort: String, LibrarySortKey {
    case title, artist, album, year, duration, dateAdded, trackNumber, playlistOrder
    var title: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .year: "Year"
        case .duration: "Duration"
        case .dateAdded: "Recently Added"
        case .trackNumber: "Track Number"
        case .playlistOrder: "Playlist Order"
        }
    }
    var defaultDescending: Bool { self == .dateAdded || self == .year }
    func ascending(_ lhs: LibraryTrack, _ rhs: LibraryTrack) -> Bool {
        switch self {
        case .title: return ordered(lhs.title, rhs.title)
        case .artist: return lhs.artistKey == rhs.artistKey ? ordered(lhs.title, rhs.title) : ordered(lhs.artist, rhs.artist)
        case .album: return lhs.albumKey == rhs.albumKey ? LibraryGrouping.albumOrder(lhs, rhs) : ordered(lhs.album, rhs.album)
        case .year: return lhs.year == rhs.year ? ordered(lhs.title, rhs.title) : lhs.year < rhs.year
        case .duration: return lhs.duration < rhs.duration
        case .dateAdded: return lhs.dateAdded < rhs.dateAdded
        // Source order is preserved by `LibrarySortState.apply` for these.
        case .trackNumber, .playlistOrder: return false
        }
    }
    /// Keys offered on the main Tracks screen.
    static let library: [TrackSort] = [.title, .artist, .album, .year, .duration, .dateAdded]
}

enum AlbumSort: String, LibrarySortKey {
    case name, artist, year, dateAdded
    var title: String {
        switch self {
        case .name: "Title"
        case .artist: "Artist"
        case .year: "Year"
        case .dateAdded: "Recently Added"
        }
    }
    var defaultDescending: Bool { self == .year || self == .dateAdded }
    func ascending(_ lhs: LibraryAlbum, _ rhs: LibraryAlbum) -> Bool {
        switch self {
        case .name: ordered(lhs.name, rhs.name)
        case .artist: lhs.artist == rhs.artist ? ordered(lhs.name, rhs.name) : ordered(lhs.artist, rhs.artist)
        case .year: lhs.year == rhs.year ? ordered(lhs.name, rhs.name) : lhs.year < rhs.year
        case .dateAdded: lhs.dateAdded < rhs.dateAdded
        }
    }
}

enum ArtistSort: String, LibrarySortKey {
    case name, trackCount
    var title: String { self == .name ? "Name" : "Number of Tracks" }
    var defaultDescending: Bool { self == .trackCount }
    func ascending(_ lhs: LibraryArtist, _ rhs: LibraryArtist) -> Bool {
        self == .name || lhs.trackIDs.count == rhs.trackIDs.count ? ordered(lhs.name, rhs.name) : lhs.trackIDs.count < rhs.trackIDs.count
    }
}

enum PlaylistSort: String, LibrarySortKey {
    case modified, created, name
    var title: String {
        switch self {
        case .modified: "Recently Modified"
        case .created: "Recently Created"
        case .name: "Name"
        }
    }
    var defaultDescending: Bool { self != .name }
    func ascending(_ lhs: LibraryPlaylist, _ rhs: LibraryPlaylist) -> Bool {
        switch self {
        case .modified: lhs.dateModified < rhs.dateModified
        case .created: lhs.dateCreated < rhs.dateCreated
        case .name: ordered(lhs.name, rhs.name)
        }
    }
}

/// Persists one screen's sort key and direction.
struct LibrarySortState<Key: LibrarySortKey>: DynamicProperty {
    @AppStorage private var keyRaw: String
    @AppStorage private var descendingStorage: Bool
    private let defaultKey: Key

    init(_ screen: String, default key: Key) {
        defaultKey = key
        _keyRaw = AppStorage(wrappedValue: key.rawValue, "library.sort.\(screen).key")
        _descendingStorage = AppStorage(wrappedValue: key.defaultDescending, "library.sort.\(screen).descending")
    }

    var key: Key { Key(rawValue: keyRaw) ?? defaultKey }
    var descending: Bool { descendingStorage }

    func select(_ newKey: Key) {
        if newKey == key { descendingStorage.toggle() }
        else { keyRaw = newKey.rawValue; descendingStorage = newKey.defaultDescending }
    }

    func apply(_ items: [Key.Item]) -> [Key.Item] {
        if let track = key as? TrackSort, track == .trackNumber || track == .playlistOrder {
            return descending ? items.reversed() : items
        }
        return key.sorted(items, descending: descending)
    }
}

/// Toolbar menu: choosing the current key again flips the direction, like Files and Music.
struct LibrarySortMenu<Key: LibrarySortKey>: View {
    var state: LibrarySortState<Key>
    var options: [Key] = Array(Key.allCases)
    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button { state.select(option) } label: {
                    if option == state.key {
                        Label(option.title, systemImage: state.descending ? "chevron.down" : "chevron.up")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort")
        .accessibilityValue("\(state.key.title), \(state.descending ? "descending" : "ascending")")
    }
}
