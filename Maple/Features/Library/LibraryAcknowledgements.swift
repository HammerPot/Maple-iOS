import SwiftUI

/// Notices for third-party code compiled into the app's library features.
struct LibraryAcknowledgements: View {
    private struct Component: Identifiable {
        let name: String
        let summary: String
        let licence: String
        let resource: String
        let source: URL?
        var id: String { name }
    }

    private static let components = [
        Component(name: "TagLib",
                  summary: "Reads audio file tags, artwork and lyrics. Used unmodified, built from CXXTagLib 2.3.2 (Stephen F. Booth), which packages TagLib for Swift Package Manager.",
                  licence: "Mozilla Public License 1.1",
                  resource: "TagLib-License",
                  source: URL(string: "https://github.com/sbooth/CXXTagLib/tree/2.3.2")),
        Component(name: "UTF8-CPP",
                  summary: "UTF-8 handling used inside TagLib. Copyright 2006 Nemanja Trifunovic.",
                  licence: "Boost Software License 1.0",
                  resource: "utfcpp-License",
                  source: URL(string: "https://github.com/nemtrif/utfcpp")),
    ]

    var body: some View {
        List {
            ForEach(Self.components) { component in
                Section {
                    Text(component.summary).font(.callout)
                    LabeledContent("Licence", value: component.licence)
                    if let source = component.source {
                        Link(destination: source) { Label("Source Code", systemImage: "arrow.up.right.square") }
                    }
                    NavigationLink("Licence Text") { LicenceText(title: component.name, resource: component.resource) }
                } header: {
                    Text(component.name)
                } footer: {
                    if component.name == "TagLib" {
                        Text("The source code of TagLib, as used in Maple, is available from the link above under the terms of the Mozilla Public License 1.1. TagLib is also available from taglib.org.")
                    }
                }
            }
        }
        .navigationTitle("Acknowledgements")
    }
}

private struct LicenceText: View {
    let title: String
    let resource: String
    @State private var text: String?

    var body: some View {
        ScrollView {
            Text(text ?? "")
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .overlay { if text == nil { ProgressView() } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "txt") else {
                text = "The licence text is missing from this build."
                return
            }
            text = await Task.detached { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }.value
        }
    }
}
