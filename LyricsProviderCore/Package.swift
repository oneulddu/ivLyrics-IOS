// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LyricsProviderCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "LyricsProviderCore", targets: ["LyricsProviderCore"])],
    targets: [
        .target(name: "LyricsProviderCore"),
        .testTarget(name: "LyricsProviderCoreTests", dependencies: ["LyricsProviderCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
