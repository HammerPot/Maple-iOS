import SwiftUI
import UniformTypeIdentifiers

struct MusicButton: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @State private var importing = false
    @State private var folder = false
    @State private var showingProgress = false
    var body: some View {
        Menu("Import Music", systemImage: "plus") {
            Button("Choose Files", systemImage: "doc.badge.plus") { folder = false; importing = true }
            Button("Choose Folder", systemImage: "folder.badge.plus") { folder = true; importing = true }
            Button("Scan for New Files", systemImage: "arrow.clockwise") { library.scanForNewFiles(); showingProgress = true }
        }
        .disabled(!library.isLoaded || library.progress != nil)
        .fileImporter(isPresented: $importing, allowedContentTypes: folder ? [.folder] : [.audio, .mpeg4Movie, .data], allowsMultipleSelection: true, onCompletion: importSelection)
        .sheet(isPresented: $showingProgress) { LibraryImportSheet() }
    }
    private func importSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): library.startImport(urls); showingProgress = true
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
                        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                        Text(progress.fileName).font(.headline)
                        Text("\(progress.completed) of \(progress.total) files processed").foregroundStyle(.secondary)
                        Button("Cancel Import", role: .cancel) { library.cancelImport() }
                    } footer: { Text("Tracks already imported are kept if you cancel.") }
                } else if let summary = library.importSummary {
                    Section {
                        Label("\(summary.imported) imported", systemImage: "checkmark.circle")
                        Label("\(summary.duplicates) duplicates skipped", systemImage: "doc.on.doc")
                        Label("\(summary.failures.count) failed", systemImage: "exclamationmark.triangle")
                        if summary.cancelled { Text("Import cancelled") }
                    }
                    if !summary.failures.isEmpty { Section("Could Not Import") { ForEach(Array(summary.failures.enumerated()), id: \.offset) { Text($0.element).font(.callout) } } }
                }
                Section { Text("Files are checked for native playback support. Tracks with a matching title and artist are skipped before their audio is copied.").font(.callout).foregroundStyle(.secondary) }
            }
            .navigationTitle("Import Music").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(library.progress != nil) } }
            .interactiveDismissDisabled(library.progress != nil)
        }
    }
}

extension Notification.Name { static let clearMapleLibrary = Notification.Name("clearMapleLibrary") }
/// Compatibility for the existing Settings action; ContentView routes this to its injected store.
func clearDocumentsDirectory() { NotificationCenter.default.post(name: .clearMapleLibrary, object: nil) }
