import SwiftUI
import Observation

@MainActor @Observable
final class ToastCenter {
    struct Action { let title: String; let perform: @MainActor () -> Void }
    struct Notice: Identifiable { let id = UUID(); let message: String; var action: Action? = nil }
    var notice: Notice?
    @ObservationIgnored private var dismissal: Task<Void, Never>?
    func show(_ message: String) { show(message, action: nil) }
    /// A notice with one action button stays a little longer so there is time to use it.
    func show(_ message: String, action: Action?) {
        dismissal?.cancel(); notice = Notice(message: message, action: action)
        let seconds = action == nil ? 5 : 8
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.notice = nil
        }
    }
    func show(_ error: Error) {
        // The user dismissing a passkey sheet or a cancelled task is not an error worth a toast.
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        show(MapleError.normalize(error).localizedDescription)
    }
}
struct ToastOverlay: ViewModifier {
    @Environment(ToastCenter.self) private var toasts
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let notice = toasts.notice {
                HStack {
                    Image(systemName: "info.circle")
                    Text(notice.message).font(.callout)
                    if let action = notice.action {
                        Button(action.title) { toasts.notice = nil; action.perform() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    Button("Dismiss", systemImage: "xmark") { toasts.notice = nil }.labelStyle(.iconOnly)
                }
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding().accessibilityElement(children: notice.action == nil ? .combine : .contain)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
}

struct ArtworkView: View {
    var url: URL?
    var data: Data? = nil
    @Environment(AppServices.self) private var services
    @State private var localData: Data?
    var body: some View {
        Group {
            if let data = data ?? localData, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() }
            else { fallback }
        }
        .clipped().accessibilityHidden(true)
        .task(id: url) {
            localData = nil
            if let url {
                if url.isFileURL { localData = try? await Task.detached { try Data(contentsOf: url) }.value }
                else { localData = try? await services.http.image(at: url) }
            }
        }
    }
    private var fallback: some View { Rectangle().fill(.quaternary).overlay { Image(systemName: "music.note").foregroundStyle(.secondary) } }
}
struct AvatarView: View {
    let userID: String
    var data: Data? = nil
    @Environment(AppServices.self) private var services
    @State private var downloaded: Data?
    var body: some View {
        Group {
            if let data = data ?? downloaded, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
        }
        .clipShape(Circle()).accessibilityHidden(true)
        .task(id: userID) { downloaded = try? await services.api.avatar(id: userID) }
    }
}
enum MapleFormat {
    static func duration(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? min(max(seconds, 0), 86400) : 0
        return Duration.seconds(safe).formatted(.time(pattern: safe >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
    static func relative(_ date: Date, to now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
