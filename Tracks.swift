import SwiftUI
import AVFoundation

struct Tracks: View {
	@Binding var localFiles: [URL]
	var body: some View {
		VStack {
			// MusicButton()
			
			if localFiles.isEmpty {
				Text("No music files found")
					.font(.headline)
					.foregroundColor(.gray)
					.padding()
			} else {
				List {
					ForEach(localFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }), id: \.self) { file in
						VStack(alignment: .leading) {
							Text(file.lastPathComponent)
						}
					}
				}
			}
		}
		.onAppear {
			localFiles = loadLocalFiles()
		}
	}
}