// swift-tools-version: 6.0
import PackageDescription

// The menu bar app. `./build-app.sh` builds it and wraps it into `build/The List.app`.
let package = Package(
    name: "TheList",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../TheListCore"),
    ],
    targets: [
        .executableTarget(
            name: "TheList",
            dependencies: [.product(name: "TheListCore", package: "TheListCore")]
        ),
    ]
)
