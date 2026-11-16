import SwiftUI
import UniformTypeIdentifiers

/// "Add music" entry point: files, a folder, or files already copied in with the Files app.
/// `prominent` renders the two primary choices as buttons for empty states.
struct MusicButton: View {
    enum Style { case menu, prominent }
    var style: Style = .menu
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @State private var picker: PickerKind?
    @State private var showingProgress = false

    /// `.audio` plus extensions some systems don't declare as audio (Opus is playable on iOS 26).
    private static let audioTypes: [UTType] = [.audio] + ["opus", "flac", "m4b"].compactMap { UTType(filenameExtension: $0) }

    private enum PickerKind: Identifiable {
        case files, folder
        var id: Self { self }
    }

    var body: some View {
        content
            .disabled(!library.isLoaded || library.progress != nil)
            .fileImporter(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } }),
                          allowedContentTypes: picker == .folder ? [.folder] : Self.audioTypes,
                          allowsMultipleSelection: true, onCompletion: importSelection)
            .sheet(isPresented: $showingProgress) { LibraryImportSheet() }
    }

    @ViewBuilder private var content: some View {
        switch style {
        case .menu:
            Menu {
                Button("Choose Files", systemImage: "doc.badge.plus") { picker = .files }
                Button("Choose Folder", systemImage: "folder.badge.plus") { picker = .folder }
                Divider()
                Button("Check Files App Folder", systemImage: "arrow.clockwise") {
                    library.scanForNewFiles(); showingProgress = true
                }
            } label: {
                Label("Add Music", systemImage: "plus")
            }
        case .prominent:
            VStack(spacing: 10) {
                Button { picker = .files } label: {
                    Label("Choose Files", systemImage: "doc.badge.plus").frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                Button { picker = .folder } label: {
                    Label("Choose a Folder", systemImage: "folder.badge.plus").frame(maxWidth: 260)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }

    private func importSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls) where !urls.isEmpty:
            library.startImport(urls); showingProgress = true
        case .success: break
        case .failure(let error): toasts.show(error)
        }
    }
}

struct LibraryImportSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let progress = library.progress {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            if progress.total > 0 {
                                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                                Text("\(progress.completed) of \(progress.total) files")
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            } else {
                                ProgressView()
                            }
                            Text(progress.fileName).font(.headline).lineLimit(2)
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                        Button("Stop Importing", role: .destructive) { library.cancelImport() }
                    } footer: {
                        Text("Tracks imported so far are kept if you stop.")
                    }
                } else if let summary = library.importSummary {
                    Section {
                        LabeledContent { Text(summary.imported.formatted()) } label: {
                            Label("Added", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        LabeledContent { Text(summary.duplicates.formatted()) } label: {
                            Label("Already in Library", systemImage: "square.on.square").foregroundStyle(.secondary)
                        }
                        LabeledContent { Text(summary.failures.count.formatted()) } label: {
                            Label("Couldn’t Import", systemImage: "exclamationmark.triangle.fill").foregroundStyle(summary.failures.isEmpty ? Color.secondary : Color.orange)
                        }
                    } header: {
                        Text(summary.cancelled ? "Import Stopped" : "Import Complete")
                    } footer: {
                        if summary.duplicates > 0 {
                            Text("Files with the same title and artist as a track in your library are skipped without being copied.")
                        }
                    }
                    if !summary.failures.isEmpty {
                        Section("Couldn’t Import") {
                            ForEach(Array(summary.failures.enumerated()), id: \.offset) { Text($0.element).font(.callout) }
                        }
                    }
                } else {
                    Section { Text("No new music found.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Add Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { library.dismissImportSummary(); dismiss() }.disabled(library.progress != nil)
                }
            }
            .interactiveDismissDisabled(library.progress != nil)
        }
        .presentationDetents([.medium, .large])
    }
}

extension Notification.Name { static let clearMapleLibrary = Notification.Name("clearMapleLibrary") }

/// Called by the existing Settings "Clear Documents" action (after its own confirmation).
/// `ContentView` routes this to `LibraryStore.clearLibrary()`.
func clearDocumentsDirectory() { NotificationCenter.default.post(name: .clearMapleLibrary, object: nil) }
