//
//  ContentView.swift
//  Maple
//
//  Created by Potter on 3/23/25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        MusicButton()
        TabView {
            Tab("Home", systemImage: "house") {
                Home()
            }
            Tab("Search", systemImage: "magnifyingglass") {
            }
            Tab("Account", systemImage: "person.crop.circle.fill") {
                Login()
            }
        }
    }
}
#Preview {
    ContentView()
}
