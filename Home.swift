//
//  Home.swift
//  Maple
//
//  Created by Potter on 3/23/25.
//

import SwiftUI

struct Home: View {
    var body: some View {
       NavigationStack {
           List {
               NavigationLink("Tracks", value: "Tracks")
               NavigationLink("Playlists", value: "Playlists")
               NavigationLink("Albums", value: "Albums")
               NavigationLink("Artists", value: "Artists")
           }
           .navigationTitle("Home")
           .navigationDestination(for: String.self) { content in
               Content()
           }
       }
    }
}

#Preview {
    Home()
}
