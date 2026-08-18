// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LocalHistory",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "LocalHistory", targets: ["LocalHistoryApp"])
    ],
    targets: [
        .target(
            name: "LocalHistoryCore",
            path: "Sources/LocalHistoryCore"
        ),
        .executableTarget(
            name: "LocalHistoryApp",
            dependencies: ["LocalHistoryCore"],
            path: "Sources/LocalHistoryApp",
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("SwiftUI", .when(platforms: [.macOS])),
                .linkedFramework("ApplicationServices", .when(platforms: [.macOS])),
                .linkedFramework("CoreGraphics", .when(platforms: [.macOS])),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
                .linkedFramework("Security", .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "LocalHistoryCoreTests",
            dependencies: ["LocalHistoryCore"],
            path: "Tests/LocalHistoryCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
