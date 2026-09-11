// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Duo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Duo",
            path: "Sources/Duo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
