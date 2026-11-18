// swift-tools-version: 6.0
// KSSCore: platform-independent logic of Scribe Sync (Amazon API, sync engine,
// correction merging, Notes rendering). Builds and tests on macOS and Linux.
import PackageDescription

let package = Package(
    name: "KSSCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KSSCore", targets: ["KSSCore"]),
    ],
    targets: [
        .target(name: "KSSCore"),
        .testTarget(name: "KSSCoreTests", dependencies: ["KSSCore"]),
    ]
)
