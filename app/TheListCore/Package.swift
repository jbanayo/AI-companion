// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TheListCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TheListCore", targets: ["TheListCore"]),
    ],
    targets: [
        .target(name: "TheListCore"),
        // Runs spec/fixtures/ and the file-safety checks. Stands in for XCTest until Xcode is
        // installed: the Command Line Tools ship neither XCTest nor Swift Testing.
        .executableTarget(
            name: "fixture-check",
            dependencies: ["TheListCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
