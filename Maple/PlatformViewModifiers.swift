import SwiftUI

extension View {
    @ViewBuilder
    func mapleTextInput() -> some View {
        #if os(macOS)
        self.autocorrectionDisabled()
        #else
        self.autocorrectionDisabled().textInputAutocapitalization(.never)
        #endif
    }

    @ViewBuilder
    func mapleInlineTitle() -> some View {
        #if os(macOS)
        self
        #else
        self.navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
