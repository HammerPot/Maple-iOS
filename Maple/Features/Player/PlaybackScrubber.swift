import SwiftUI

struct PlaybackScrubber: View {
    @Environment(PlaybackController.self) private var player
    @State private var draft = 0.0
    @State private var dragging = false
    var body: some View {
        let elapsed = dragging ? draft : player.position.seconds
        VStack(spacing: 4) {
            Slider(value: Binding(get: { dragging ? draft : player.position.seconds }, set: { draft = $0 }),
                   in: 0...max(1, player.duration), onEditingChanged: editing)
                .disabled(player.currentItem == nil || player.duration <= 0)
                .accessibilityLabel("Playback Position")
                .accessibilityValue("\(MapleFormat.duration(elapsed)) of \(MapleFormat.duration(player.duration))")
                .accessibilityAdjustableAction { direction in
                    let change = direction == .increment ? 10.0 : -10.0
                    Task { await player.seek(to: player.position.seconds + change) }
                }
            HStack {
                Text(MapleFormat.duration(elapsed))
                Spacer()
                Text("−" + MapleFormat.duration(max(0, player.duration - elapsed)))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
    private func editing(_ editing: Bool) {
        if editing { draft = player.position.seconds; dragging = true }
        else {
            let seconds = draft; dragging = false
            Task { await player.seek(to: seconds) }
        }
    }
}
