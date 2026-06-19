// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "AudioPairingClient",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "AudioPairingClient",
            targets: ["AudioPairingClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "AudioPairingClient",
            dependencies: ["Starscream"],
            path: "Sources",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]),
        .testTarget(
            name: "AudioPairingClientTests",
            dependencies: ["AudioPairingClient"],
            path: "Tests"),
    ]
)
