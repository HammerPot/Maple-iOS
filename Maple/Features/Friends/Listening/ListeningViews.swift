import SwiftUI

/// Compact listening summary for list rows.
struct ListeningLine: View {
    let status: ListeningStatus
    let receivedAt: Date
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        switch status {
        case .current(let current):
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    PlayingIndicator(playing: current.playing)
                    Text("\(Text(current.title).foregroundStyle(.primary))\(Text(current.artist.isEmpty ? "" : " · \(current.artist)").foregroundStyle(.secondary))")
                }
                .font(.subheadline)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                ListeningProgressBar(clock: ListeningClock(current, receivedAt: receivedAt))
            }
        case .lastPlayed(let last):
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(LastPlayedText.line(last, now: context.date))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
        case .nothing, .hidden:
            EmptyView()
        }
    }
}

/// A thin progress bar that advances locally between server updates.
struct ListeningProgressBar: View {
    let clock: ListeningClock
    var body: some View {
        if clock.knownDuration != nil {
            if clock.playing {
                TimelineView(.periodic(from: clock.receivedAt, by: 1)) { context in
                    bar(clock.fraction(at: context.date) ?? 0)
                }
            } else {
                bar(clock.fraction(at: clock.receivedAt) ?? 0)
            }
        }
    }
    private func bar(_ value: Double) -> some View {
        ProgressView(value: value).progressViewStyle(.linear).tint(clock.playing ? Color.accentColor : .secondary)
            .accessibilityHidden(true)
    }
}

struct PlayingIndicator: View {
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if playing {
                Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                    .foregroundStyle(.tint)
            } else {
                Image(systemName: "pause.fill").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .accessibilityHidden(true)
    }
}

enum LastPlayedText {
    static func line(_ last: LastPlayed, now: Date) -> String {
        let artist = last.artist.isEmpty ? "" : " · \(last.artist)"
        guard let date = last.playedAt else { return "Last played \(last.title)\(artist)" }
        return "Last played \(last.title)\(artist), \(MapleFormat.relative(date, to: now))"
    }
}

/// VoiceOver description of a person's listening, e.g. "Listening to Song by Artist, 1:02 of 3:40".
enum ListeningAccessibility {
    static func label(_ status: ListeningStatus, receivedAt: Date, now: Date = .now) -> String? {
        switch status {
        case .current(let current):
            let clock = ListeningClock(current, receivedAt: receivedAt)
            var text = current.playing ? "Listening to \(current.title)" : "Paused \(current.title)"
            if !current.artist.isEmpty { text += " by \(current.artist)" }
            if let total = clock.knownDuration {
                text += ", \(MapleFormat.duration(clock.elapsed(at: now))) of \(MapleFormat.duration(total))"
            }
            return text
        case .lastPlayed(let last):
            return LastPlayedText.line(last, now: now)
        case .nothing, .hidden:
            return nil
        }
    }
}

/// Large listening card for the friend detail and profile screens.
struct ListeningCard: View {
    let userID: String
    let status: ListeningStatus
    let receivedAt: Date
    var hiddenText = "Listening activity is private."
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var artworkSize = 220

    var body: some View {
        switch status {
        case .current(let current):
            VStack(spacing: 14) {
                artwork(current.artwork, size: min(artworkSize, 220))
                VStack(spacing: 4) {
                    Label(current.playing ? "Now Playing" : "Paused", systemImage: current.playing ? "waveform" : "pause.fill")
                        .font(.caption.weight(.semibold)).textCase(.uppercase)
                        .foregroundStyle(current.playing ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(current.title).font(.title3.bold()).multilineTextAlignment(.center)
                    if !current.byline.isEmpty {
                        Text(current.byline).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                ElapsedTimeline(clock: ListeningClock(current, receivedAt: receivedAt))
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .modifier(ListeningAccessibilityUpdate(playing: current.playing) { now in
                ListeningAccessibility.label(status, receivedAt: receivedAt, now: now) ?? ""
            })
        case .lastPlayed(let last):
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                : AnyLayout(HStackLayout(spacing: 14))
            layout {
                artwork(last.artwork, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Last Played").font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                    Text(last.title).font(.headline)
                    if !last.byline.isEmpty { Text(last.byline).font(.subheadline).foregroundStyle(.secondary) }
                    if let date = last.playedAt {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(MapleFormat.relative(date, to: context.date)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        case .nothing:
            Label("Nothing played yet.", systemImage: "music.note").foregroundStyle(.secondary)
        case .hidden:
            Label(hiddenText, systemImage: "eye.slash").foregroundStyle(.secondary)
        }
    }

    private func artwork(_ id: String?, size: CGFloat) -> some View {
        ArtworkView(url: id.flatMap { MapleAPI.artworkURL(userID: userID, artwork: $0) })
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 16 : 8, style: .continuous))
            .shadow(color: .black.opacity(size > 100 ? 0.15 : 0), radius: 12, y: 6)
    }
}

/// Progress bar with elapsed and remaining time, advancing locally.
struct ElapsedTimeline: View {
    let clock: ListeningClock
    var body: some View {
        if clock.knownDuration != nil {
            TimelineView(.periodic(from: clock.receivedAt, by: 1)) { context in
                let now = clock.playing ? context.date : clock.receivedAt
                VStack(spacing: 4) {
                    ProgressView(value: clock.fraction(at: now) ?? 0)
                        .tint(clock.playing ? Color.accentColor : .secondary)
                    HStack {
                        Text(MapleFormat.duration(clock.elapsed(at: now)))
                        Spacer()
                        Text("−" + MapleFormat.duration(clock.remaining(at: now) ?? 0))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Refresh the spoken elapsed time alongside the visual progress, rather than only on socket events.
struct ListeningAccessibilityUpdate: ViewModifier {
    let playing: Bool
    let label: (Date) -> String

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: playing ? 1 : 60)) { context in
            content.accessibilityLabel(label(context.date))
        }
    }
}
