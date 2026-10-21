import MusicKit

// The system Music app can be controlled on iOS; macOS playback belongs to Maple.
#if os(macOS)
typealias MapleMusicPlayer = ApplicationMusicPlayer
#else
typealias MapleMusicPlayer = SystemMusicPlayer
#endif
