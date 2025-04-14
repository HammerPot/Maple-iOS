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
    @State private var localFiles: [URL] = []
    var body: some View {
        List {
            ForEach(localFiles, id: \.self) { file in
                Text(file.lastPathComponent)
            }
        }
        .onAppear {
            loadLocalFiles()
        }
    }


    private func loadLocalFiles() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let localFiles = try FileManager.default.contentsOfDirectory(at: documentsDirectory,
                                                                    includingPropertiesForKeys: [.fileSizeKey])
        } catch {
            print("Error loading local files: \(error.localizedDescription)")
        }
	}

}

#Preview {
    Content()
}
