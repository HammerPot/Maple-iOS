//
//  MusicButton.swift
//  Maple
//
//  Created by Potter on 3/26/25.
//

import SwiftUI
import MusicKit

struct MusicButton: View {
    var body: some View {
        VStack {
            Button("Request Music Access") {
                Task {
                    await requestMusicAuthorization()
                }
            }
        }
    }
    
    func requestMusicAuthorization() async {
        let status = await MusicAuthorization.request()
        
        switch status {
        case .authorized:
            print("Access granted to Apple Music")
        case .denied:
            print("Access denied")
        case .restricted:
            print("Access restricted")
        case .notDetermined:
            print("Authorization not determined")
        @unknown default:
            print("Unknown authorization status")
        }
    }
}

#Preview {
    MusicButton()
}
