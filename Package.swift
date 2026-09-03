// swift-tools-version: 5.9

import PackageDescription
import Foundation

let cliInfoPlistPath = ProcessInfo.processInfo.environment["LOCALHISTORY_CLI_INFO_PLIST"]

var packageDependencies: [Package.Dependency] = []
var appDependencies: [Target.Dependency] = [
    "LocalHistoryCore",
    "AppleScreenTime",
    "AppleSystemScreenTime",
    "AgentActivity",
    "LocalHistoryQueryCLI",
]
let appExcludes: [String] = [
    "AppAttestManager.swift",
    "CommitmentUploader.swift",
    "SoftwareUpdateManager.swift",
    "LocalOnlyCodexAppServerClient.swift",
]
let appSwiftSettings: [SwiftSetting] = [.define("GOALONG_UNIFIED_APP")]
let appTestExcludes: [String] = [
    "CommitmentUploaderTests.swift",
    "SoftwareUpdatePresentationStateTests.swift",
]

let package = Package(
    name: "LocalHistory",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AppleScreenTime", targets: ["AppleScreenTime"]),
        .library(name: "AppleSystemScreenTime", targets: ["AppleSystemScreenTime"]),
        .library(name: "AgentActivity", targets: ["AgentActivity"]),
        .executable(name: "LocalHistory", targets: ["LocalHistoryApp"]),
        .executable(name: "goalong", targets: ["GoalongCLI"]),
        .executable(name: "goalong-history-query", targets: ["GoalongCLI"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "AppleScreenTime",
            path: "Features/AppleScreenTime/Sources"
        ),
        .target(
            name: "LocalHistoryCore",
            path: "Sources/LocalHistoryCore"
        ),
        .target(
            name: "AppleSystemScreenTime",
            dependencies: ["AppleScreenTime"],
            path: "Features/AppleSystemScreenTime/Sources",
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedLibrary("sqlite3", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "AgentActivity",
            dependencies: ["LocalHistoryCore"],
            path: "Features/AgentActivity/Sources",
            linkerSettings: [
                .linkedLibrary("sqlite3", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "LocalHistoryApp",
            dependencies: appDependencies,
            path: "Sources/LocalHistoryApp",
            exclude: appExcludes,
            swiftSettings: appSwiftSettings,
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("SwiftUI", .when(platforms: [.macOS])),
                .linkedFramework("ApplicationServices", .when(platforms: [.macOS])),
                .linkedFramework("CoreGraphics", .when(platforms: [.macOS])),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
                .linkedFramework("LocalAuthentication", .when(platforms: [.macOS])),
                .linkedFramework("Security", .when(platforms: [.macOS])),
                .linkedFramework("ServiceManagement", .when(platforms: [.macOS])),
                .linkedLibrary("sqlite3", .when(platforms: [.macOS])),
                .unsafeFlags(
                    ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                    .when(platforms: [.macOS])
                ),
            ]
        ),
        .target(
            name: "LocalHistoryQueryCLI",
            dependencies: [
                "LocalHistoryCore", "AppleScreenTime", "AppleSystemScreenTime", "AgentActivity",
            ],
            path: "Sources/LocalHistoryQueryCLI"
        ),
        .executableTarget(
            name: "GoalongCLI",
            dependencies: ["LocalHistoryQueryCLI"],
            path: "Sources/GoalongCLI",
            linkerSettings: cliInfoPlistPath.map {
                [
                    .unsafeFlags(
                        [
                            "-Xlinker", "-sectcreate",
                            "-Xlinker", "__TEXT",
                            "-Xlinker", "__info_plist",
                            "-Xlinker", $0,
                        ],
                        .when(platforms: [.macOS])
                    )
                ]
            } ?? []
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
            name: "AgentActivityTests",
            dependencies: ["AgentActivity"],
            path: "Features/AgentActivity/Tests"
        ),
        .testTarget(
            name: "LocalHistoryAppTests",
            dependencies: ["LocalHistoryApp", "LocalHistoryCore", "AppleScreenTime", "AppleSystemScreenTime"],
            path: "Tests/LocalHistoryAppTests",
            exclude: appTestExcludes,
            swiftSettings: appSwiftSettings
        ),
        .testTarget(
            name: "LocalHistoryQueryCLITests",
            dependencies: ["LocalHistoryQueryCLI", "AppleScreenTime", "AppleSystemScreenTime"],
            path: "Tests/LocalHistoryQueryCLITests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
