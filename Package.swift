// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuHub",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MenuHub", targets: ["MenuHub"]),
        .library(name: "MenuHubSparkle", targets: ["MenuHubSparkle"]),
    ],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")],
    targets: [
        .target(name: "MenuHub", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "MenuHubSparkle", dependencies: ["MenuHub", .product(name: "Sparkle", package: "Sparkle")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "MenuHubTests", dependencies: ["MenuHub"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
