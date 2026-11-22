// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Inkwell",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Software updates. A binary framework: build.sh copies it into the app and signs it.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // llama.cpp, the engine for local models. Fetched by scripts/fetch_llama.sh (build.sh runs it).
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .executableTarget(
            name: "Inkwell",
            dependencies: ["llama", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Inkwell",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        ),
    ]
)
