import SwiftUI
import UniformTypeIdentifiers

struct LyricsPanel: View {
    @Environment(PlaybackController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @State private var document = LyricsDocument(lines: [])
    @State private var importing = false
    @State private var reading = false
    @State private var removeConfirmation = false
    private var track: LibraryTrack? { player.currentItem?.libraryID.flatMap { library.track($0) } }
    var body: some View {
        Group {
            if track != nil {
                if document.lines.contains(where: { !$0.text.isEmpty }) {
                    LyricsLines(document: document)
                } else {
                    ContentUnavailableView("No Lyrics", systemImage: "quote.bubble",
                        description: Text("Attach an LRC or text file using the Add Lyrics button."))
                }
            } else {
                ContentUnavailableView("No Local Lyrics", systemImage: "quote.bubble",
                    description: Text("Lyrics are available for tracks in your local library."))
            }
        }
        .navigationTitle("Lyrics").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if track != nil {
                HStack {
                    Button("Add Lyrics", systemImage: "doc.badge.plus") { importing = true }.disabled(reading)
                    Spacer()
                    if track?.lyrics != nil { Button("Remove Lyrics", systemImage: "trash", role: .destructive) { removeConfirmation = true } }
                }.padding().background(.bar)
            }
        }
        .task(id: track?.lyrics) {
            let text = track?.lyrics ?? ""
            document = await Task.detached { LyricsDocument.parse(text) }.value
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text] + [UTType(filenameExtension: "lrc")].compactMap { $0 }, onCompletion: importFile)
        .alert("Remove Lyrics?", isPresented: $removeConfirmation) {
            Button("Remove", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The stored lyrics will be removed from this track. The audio file is kept.") }
        .overlay { if reading { ProgressView("Reading lyrics…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
    }
    private func importFile(_ result: Result<URL, Error>) {
        guard let id = track?.id else { return }
        reading = true
        Task {
            defer { reading = false }
            do {
                let text = try await ExternalLyricsReader().read(result.get())
                try await library.setLyrics(text, for: id)
                toasts.show("Lyrics added")
            } catch { toasts.show(error) }
        }
    }
    private func remove() {
        guard let id = track?.id else { return }
        Task { do { try await library.setLyrics(nil, for: id) } catch { toasts.show(error) } }
    }
}

private struct LyricsLines: View {
    @Environment(PlaybackController.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let document: LyricsDocument
    @State private var resumeAt = Date.distantPast
    var body: some View {
        let active = document.currentLine(at: player.position.seconds)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(document.lines) { line in
                        if let time = line.time {
                            Button { Task { await player.seek(to: time) } } label: {
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.title2.weight(line.id == active ? .bold : .regular))
                                    .foregroundStyle(line.id == active ? Color.primary : Color.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Seeks to \(MapleFormat.duration(time))")
                            .accessibilityAddTraits(line.id == active ? .isSelected : [])
                            .id(line.id)
                        } else {
                            Text(line.text.isEmpty ? " " : line.text).font(.title3).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(24)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating || phase == .tracking { resumeAt = .now.addingTimeInterval(5) }
            }
            .onChange(of: active) { _, id in
                guard document.synced, Date.now >= resumeAt, let id else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}
