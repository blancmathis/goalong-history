// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LocalHistory",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AppleScreenTime", targets: ["AppleScreenTime"]),
        .executable(name: "LocalHistory", targets: ["LocalHistoryApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(
            name: "AppleScreenTime",
            path: "Features/AppleScreenTime/Sources"
        ),
        .target(
            name: "LocalHistoryCore",
            path: "Sources/LocalHistoryCore"
        ),
        .executableTarget(
            name: "LocalHistoryApp",
            dependencies: [
                "LocalHistoryCore",
                "AppleScreenTime",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/LocalHistoryApp",
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("SwiftUI", .when(platforms: [.macOS])),
                .linkedFramework("ApplicationServices", .when(platforms: [.macOS])),
                .linkedFramework("CoreGraphics", .when(platforms: [.macOS])),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
                .linkedFramework("LocalAuthentication", .when(platforms: [.macOS])),
                .linkedFramework("Security", .when(platforms: [.macOS])),
                .linkedFramework("ServiceManagement", .when(platforms: [.macOS])),
                .unsafeFlags(
                    ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                    .when(platforms: [.macOS])
                ),
            ]
        ),
        .testTarget(
            name: "LocalHistoryCoreTests",
            dependencies: ["LocalHistoryCore"],
            path: "Tests/LocalHistoryCoreTests"
        ),
        .testTarget(
            name: "AppleScreenTimeTests",
            dependencies: ["AppleScreenTime"],
            path: "Features/AppleScreenTime/Tests"
        ),
        .testTarget(
            name: "LocalHistoryAppTests",
            dependencies: ["LocalHistoryApp", "LocalHistoryCore", "AppleScreenTime"],
            path: "Tests/LocalHistoryAppTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
