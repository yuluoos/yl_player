// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "yl_player_apple",
    platforms: [
        .iOS("15.0"),
        .macOS("12.0")
    ],
    products: [
        .library(name: "yl-player-apple", targets: ["yl_player_apple"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(name: "yl_player_media_core", path: "../yl_player_media_core")
    ],
    targets: [
        .target(
            name: "yl_player_apple",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "yl-player-media-core", package: "yl_player_media_core"),
                .product(name: "YlFFmpegBridge", package: "yl_player_media_core")
            ]
        )
    ]
)
