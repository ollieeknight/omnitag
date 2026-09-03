// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "omnitag",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MediaCore", targets: ["MediaCore"]),
        .library(name: "TagIO", targets: ["TagIO"]),
        .library(name: "LibraryIndex", targets: ["LibraryIndex"]),
        .library(name: "EditEngine", targets: ["EditEngine"]),
        .library(name: "MetadataAPI", targets: ["MetadataAPI"])
    ],
    targets: [
        .executableTarget(name: "OmniTagApp", dependencies: ["MediaCore", "TagIO", "LibraryIndex", "EditEngine", "MetadataAPI"]),
        .target(name: "MediaCore"),
        .target(name: "TagIO", dependencies: ["MediaCore"]),
        .target(name: "EditEngine", dependencies: ["MediaCore", "TagIO"]),
        .target(name: "MetadataAPI", dependencies: ["MediaCore"]),
        .target(name: "LibraryIndex", dependencies: ["MediaCore"]),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore"]),
        .testTarget(name: "TagIOTests", dependencies: ["TagIO", "LibraryIndex"]),
        .testTarget(name: "EditEngineTests", dependencies: ["EditEngine"]),
        .testTarget(
            name: "MetadataAPITests", dependencies: ["MetadataAPI", "MediaCore", "TagIO", "EditEngine"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "OmniTagAppTests", dependencies: ["OmniTagApp", "MediaCore", "MetadataAPI"])
    ]
)
