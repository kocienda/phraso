// swift-tools-version: 6.0
// Phraseo: word-highlighted captions for Final Cut Pro, drawn on the Mac.
//
//   PhraseoKit  the engine: transcript, cards, styles, renderer, movie writer, FCPXML
//   phraseo     the command-line tool on top of it
//   PhraseoApp  the SwiftUI app (bundled by Scripts/bundle-app.sh)

import PackageDescription

let package = Package(
    name: "Phraseo",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PhraseoKit", targets: ["PhraseoKit"]),
        .executable(name: "phraseo", targets: ["phraseo"]),
        .executable(name: "PhraseoApp", targets: ["PhraseoApp"]),
    ],
    targets: [
        .target(
            name: "PhraseoKit",
            resources: [.copy("Presets")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "phraseo",
            dependencies: ["PhraseoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "PhraseoApp",
            dependencies: ["PhraseoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "PhraseoKitTests",
            dependencies: ["PhraseoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
