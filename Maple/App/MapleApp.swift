import SwiftUI

@main
struct MapleApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var services = AppServices()
    @State private var wasInBackground = false
    var body: some Scene {
        WindowGroup {
            root
                .modifier(ToastOverlay())
                .environment(services)
                .environment(services.library)
                .environment(services.auth)
                .environment(services.friends)
                .environment(services.toasts)
                .task { await services.start() }
                // Only a real return from the background (suspension may have lapsed the playback lease or left
                // an unverified session). Control Center or a system alert only pass through `.inactive`.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { wasInBackground = true }
                    else if phase == .active, wasInBackground {
                        wasInBackground = false
                        Task { await services.sceneBecameActive() }
                    }
                }
        }
    }

    @ViewBuilder private var root: some View {
        #if DEBUG
        if AccountVerificationSupport.showsChecks {
            NavigationStack { AccountVerificationChecks() }
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }
}
