//
//  MapleApp.swift
//  Maple
//
//  Created by Potter on 3/23/25.
//

import SwiftUI

@main
struct MapleApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if let cookies = loadCookies() { restoreCookies(cookies) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { AppSocketManager.shared.connect() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { AppSocketManager.shared.refreshPlayback() }
                }
        }
    }
}
