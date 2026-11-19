import SwiftUI

struct UpNextView: View {
    @Environment(PlaybackController.self) private var player
    var body: some View {
        List {
            if let current = player.currentItem {
                Section("Now Playing") {
                    VStack(alignment: .leading) {
                        Text(current.title)
                        Text(current.artist).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if player.playingFromMusic { Text("Playing from Music. Your Maple queue is saved below.").foregroundStyle(.secondary) }
            Section("Up Next") {
                ForEach(player.queue.upcoming) { entry in
                    Button { Task { await player.playEntry(entry.id) } } label: {
                        VStack(alignment: .leading) {
                            Text(entry.item.title).foregroundStyle(.primary)
                            Text(entry.item.artist).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu { Button("Remove from Queue", systemImage: "minus.circle", role: .destructive) { player.removeEntries([entry.id]) } }
                    .accessibilityAction(named: "Remove from Queue") { player.removeEntries([entry.id]) }
                }
                .onDelete { offsets in player.removeEntries(Set(offsets.compactMap { player.queue.upcoming.indices.contains($0) ? player.queue.upcoming[$0].id : nil })) }
                .onMove { player.moveUpcoming(from: $0, to: $1) }
                if player.queue.upcoming.isEmpty { Text("Nothing queued").foregroundStyle(.secondary) }
            }.disabled(player.playingFromMusic)
        }
        .navigationTitle("Up Next")
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton().disabled(player.playingFromMusic) } }
    }
}
