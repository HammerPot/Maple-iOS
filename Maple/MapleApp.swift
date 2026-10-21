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
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 320)
                #endif
                .task { AppSocketManager.shared.connect() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { AppSocketManager.shared.refreshPlayback() }
                }
        }
        #if os(macOS) || os(visionOS)
        .defaultSize(width: 960, height: 720)
        #endif
    }
}
