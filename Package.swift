// swift-tools-version: 6.0
// Phraso: word-highlighted captions for Final Cut Pro, drawn on the Mac.
//
//   PhrasoKit  the engine: transcript, cards, styles, renderer, movie writer, FCPXML
//   phraso     the command-line tool on top of it
//   PhrasoApp  the app (bundled by Scripts/bundle-app.sh)

import PackageDescription

let package = Package(
    name: "Phraso",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PhrasoKit", targets: ["PhrasoKit"]),
        .executable(name: "phraso", targets: ["phraso"]),
        .executable(name: "PhrasoApp", targets: ["PhrasoApp"]),
    ],
    targets: [
        .target(
            name: "PhrasoKit",
            resources: [.copy("Presets")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "phraso",
            dependencies: ["PhrasoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "PhrasoApp",
            dependencies: ["PhrasoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "PhrasoKitTests",
            dependencies: ["PhrasoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
