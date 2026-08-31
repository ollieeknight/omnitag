// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "omnitag",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MediaCore", targets: ["MediaCore"]),
        .library(name: "TagIO", targets: ["TagIO"]),
        .library(name: "LibraryIndex", targets: ["LibraryIndex"]),
        .library(name: "EditEngine", targets: ["EditEngine"]),
    ],
    targets: [
        .executableTarget(name: "OmniTagApp", dependencies: ["MediaCore", "TagIO", "LibraryIndex", "EditEngine"]),
        .target(name: "MediaCore"),
        .target(name: "TagIO", dependencies: ["MediaCore"]),
        .target(name: "EditEngine", dependencies: ["MediaCore", "TagIO"]),
        .target(name: "LibraryIndex", dependencies: ["MediaCore"]),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore"]),
        .testTarget(name: "TagIOTests", dependencies: ["TagIO", "LibraryIndex"]),
        .testTarget(name: "EditEngineTests", dependencies: ["EditEngine"]),
    ]
)
