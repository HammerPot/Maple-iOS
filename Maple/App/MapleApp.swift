import SwiftUI

@main
struct MapleApp: App {
    @State private var services = AppServices()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(ToastOverlay())
                .environment(services)
                .environment(services.auth)
                .environment(services.friends)
                .environment(services.toasts)
                .task { await services.start() }
        }
    }
}
