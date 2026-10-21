import SwiftUI

struct Snackbar: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var action: Action? = nil

    enum Action {
        case text(String, Color, () -> Void)
    }
}

private struct SnackbarModifier: ViewModifier {
    @Binding var snackbar: Snackbar?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let item = snackbar {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline)
                        Text(item.message).font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if case .text(let title, _, let action) = item.action {
                        Button(title) { snackbar = nil; action() }
                    }
                    Button("Dismiss notification", systemImage: "xmark") { snackbar = nil }
                        .labelStyle(.iconOnly)
                }
                .padding()
                .background(.regularMaterial)
                .task(id: item.id) {
                    AccessibilityNotification.Announcement("\(item.title). \(item.message)").post()
                    do {
                        try await Task.sleep(for: .seconds(8))
                        if snackbar?.id == item.id { snackbar = nil }
                    } catch { }
                }
            }
        }
    }
}

extension View {
    func snackbarView(snackbar: Binding<Snackbar?>) -> some View {
        modifier(SnackbarModifier(snackbar: snackbar))
    }
}
