import SwiftUI

/// Header for the signed-out screens: app mark, title and one line of context.
struct AccountFormHeader: View {
    let title: String
    let subtitle: String
    var systemImage: String? = nil
    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 44)).foregroundStyle(.tint)
                } else {
                    Image("Maple").resizable().scaledToFit().frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .accessibilityHidden(true)
            Text(title).font(.title2.bold()).foregroundStyle(Color.primary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.subheadline).foregroundStyle(Color.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .textCase(nil)
        .padding(.bottom, 8)
    }
}

/// Inline feedback below a field or form: red for problems, secondary for hints, green for confirmations.
struct FormMessage: View {
    enum Kind { case error, hint, success }
    let text: String
    var kind: Kind = .error
    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.footnote)
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
    private var symbol: String {
        switch kind {
        case .error: "exclamationmark.circle.fill"
        case .hint: "info.circle"
        case .success: "checkmark.circle.fill"
        }
    }
    private var color: Color {
        switch kind {
        case .error: .red
        case .hint: .secondary
        case .success: .green
        }
    }
}

/// A full-width form button that shows a spinner while its action runs.
struct BusyButtonLabel: View {
    let title: String
    let busy: Bool
    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if busy { ProgressView().accessibilityHidden(true) }
            Text(title).fontWeight(.semibold)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(busy ? "In progress" : "")
    }
}

extension View {
    /// Keyboard and autofill configuration for a username or email field.
    func identifierField(email: Bool = false) -> some View {
        self.textContentType(email ? .emailAddress : .username)
            .keyboardType(email ? .emailAddress : .asciiCapable)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
    /// Announces form errors to VoiceOver when they appear.
    func announcing(_ message: String?) -> some View {
        onChange(of: message) { _, new in
            if let new { AccessibilityNotification.Announcement(new).post() }
        }
    }
}

/// A visible dismissal control keeps long account forms usable with secure keyboards and large text.
private struct AccountFormKeyboard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
    }
}

extension View {
    func accountFormKeyboard() -> some View { modifier(AccountFormKeyboard()) }
}
