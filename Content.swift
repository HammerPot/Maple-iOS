//
//  Content.swift
//  Maple
//
//  Created by Potter on 3/24/25.
//

import SwiftUI
import AVFoundation
import AVFAudio



struct Content: View {
    var songs = [AVAsset]()
    var body: some View {
        Grid {
            GridRow {
                VStack {
                    Image(systemName: "globe")
                        .imageScale(.large)
                    Text("Album")
                    Text("Artist")
                }
                .padding(.bottom)
            }
            
            GridRow {
                VStack {
                    Image(systemName: "globe")
                    Text("Album")
                    Text("Artist")
                }
                .padding(.bottom)
            }
        }
    }
}

#Preview {
    Content()
}
