// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Inkwell",
    platforms: [.macOS(.v15)],
    targets: [
        // llama.cpp, the engine for local models. Fetched by scripts/fetch_llama.sh (build.sh runs it).
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .executableTarget(
            name: "Inkwell",
            dependencies: ["llama"],
            path: "Sources/Inkwell",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        ),
    ]
)
