// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Folha",
    platforms: [.iOS(.v17)],
    products: [.library(name: "Folha", targets: ["Folha"])],
    targets: [.target(name: "Folha")],
    swiftLanguageVersions: [.v5]
)
