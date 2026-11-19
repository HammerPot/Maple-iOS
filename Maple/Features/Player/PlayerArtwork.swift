import SwiftUI

struct PlayerArtwork: View {
    @Environment(PlaybackController.self) private var player
    @State private var image: UIImage?
    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary) }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityHidden(true)
            .task(id: player.artworkData) {
                let data = player.artworkData
                image = await Task.detached(priority: .userInitiated) {
                    data.flatMap { UIImage(data: $0)?.preparingForDisplay() }
                }.value
            }
    }
}
