//
//  MusicButton.swift
//  Maple
//
//  Created by Potter on 3/26/25.
//

import SwiftUI
import MusicKit
import AVFoundation



struct MusicButton: View {
    @State private var importing = false
    var body: some View {
        var content = Content()
        VStack {
            //Button("Request Music Access") {
            //    Task {
            //        await requestMusicAuthorization()
            //    }
            //}
            Button("Upload File(s?)") {
                importing = true
            }
            .fileImporter (
                isPresented: $importing,
                allowedContentTypes: [.audio]
            ) { result in
                switch result {
                case .success(let file):
                    print(file.absoluteString)
                    content.songs.append(AVURLAsset(url: file.absoluteURL))
                    print(content.songs)
                    
                case .failure(let error):
                    print(error.localizedDescription)
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
