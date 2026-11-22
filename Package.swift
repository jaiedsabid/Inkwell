// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Inkwell",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Inkwell",
            path: "Sources/Inkwell",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
