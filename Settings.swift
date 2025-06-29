//
//  Settings.swift
//  Maple
//
//  Created by Potter on 4/29/25.
//

import SwiftUI

struct Settings: View {
    @State private var webhookURL = UserDefaults.standard.string(forKey: "webhookURL") ?? ""
    @State private var mapleRPC = UserDefaults.standard.bool(forKey: "mapleRPC")
    @State private var socketIO = UserDefaults.standard.bool(forKey: "socketIO")
    @State private var musicKit = UserDefaults.standard.bool(forKey: "musicKit")
    @State private var showingAlert = false

    var body: some View {
        List{
            Section{
                Toggle("Enable MusicKit?", isOn: $musicKit)
                .onChange(of: self.musicKit) {
                    UserDefaults.standard.set(musicKit, forKey: "musicKit")
                    if musicKit == true {
                        let manager = AppleMusicManager.shared
                        manager.requestAuthorization()
                    }
                }
            } header: {
                Text("MusicKit")
            } footer: {
                Text("To make full use of this feature you must be subscribed to Apple Music. Currently your authorization status is **\(AppleMusicManager.shared.authStatus.rawValue)**. Depending on this value you may need to allow Maple to access your Apple Music library.")
            }
            Section{
                VStack{
                    Text("Webhook URL")
                    TextField(webhookURL == "" ? "https://discord.com/api/webhooks/..." : webhookURL, text: $webhookURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                        .onSubmit{
                            UserDefaults.standard.set(webhookURL, forKey: "webhookURL")
                        }
                        
                }
                VStack{
                    Toggle("Enable SocketIO?", isOn: $socketIO)
                    .onChange(of: self.socketIO) {
                            UserDefaults.standard.set(socketIO, forKey: "socketIO")
                    }
                }
                VStack{
                    Toggle("Enable MapleRPC for Discord?", isOn: $mapleRPC)
                    .onChange(of: self.mapleRPC) {
                            UserDefaults.standard.set(mapleRPC, forKey: "mapleRPC")
                    }
                }
            } header: {
                Text("Social Features")
            } footer: {
                Text("Toggling SocketIO will require restarting the app to take effect. You must have SocketIO enabled to use MapleRPC")
            }
            Section{
                MusicButton()
                Button(action: { 
                    showingAlert = true
                }) {
                    Text("Clear Documents")
                    .foregroundStyle(.red)
                }
                .alert("Warning!", isPresented: $showingAlert, actions: { 
                        Button(role: .destructive) {
                            clearDocumentsDirectory()
                        } label: {
                            Text("Delete")
                            .foregroundStyle(.red)
                        }
                        Button("Cancel", role: .cancel) {
                        }
                }, message: {
                    Text("This will delete all data saved in the Maple directory. This is irreversible! (This will not log you out of Maple nor will it change any settings)")
                })
            } header: {
                Text("File Management")
            }
        }
    }
}

#Preview {
    Settings()
}
