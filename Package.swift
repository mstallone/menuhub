// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuHub",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MenuHub", targets: ["MenuHub"])],
    targets: [
        .target(name: "MenuHub", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "MenuHubTests", dependencies: ["MenuHub"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
