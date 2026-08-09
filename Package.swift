// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ContextGauge",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "TokenHubCore", targets: ["TokenHubCore"]),
        .executable(name: "contextgauge", targets: ["TokenHubCLI"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "TokenHubCore",
            dependencies: ["CSQLite"]
        ),
        .executableTarget(
            name: "TokenHubCLI",
            dependencies: ["TokenHubCore"]
        ),
        .testTarget(
            name: "TokenHubCoreTests",
            dependencies: ["TokenHubCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
