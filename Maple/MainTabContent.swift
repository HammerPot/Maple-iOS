import SwiftUI

struct MainTabContent<Content: View>: View {
    @Binding var showPlayer: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            NowPlayingBar(showPlayer: $showPlayer)
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial)
        }
    }
}
