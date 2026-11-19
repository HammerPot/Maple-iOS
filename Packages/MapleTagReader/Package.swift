// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MapleTagReader",
    platforms: [.iOS("18.0")],
    products: [.library(name: "MapleTagReader", targets: ["MapleTagReader"])],
    dependencies: [.package(url: "https://github.com/sbooth/CXXTagLib", exact: "2.3.2")],
    targets: [.target(name: "MapleTagReader", dependencies: [.product(name: "taglib", package: "CXXTagLib")],
                      publicHeadersPath: "include", linkerSettings: [.linkedFramework("Foundation")])],
    cxxLanguageStandard: .cxx17
)
