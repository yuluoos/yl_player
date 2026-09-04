// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "yl_player_macos",
    platforms: [
        .macOS("12.0")
    ],
    products: [
        .library(name: "yl-player-macos", targets: ["yl_player_macos"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .binaryTarget(
            name: "YlFFmpegBridge",
            path: "Frameworks/YlFFmpegBridge.xcframework"
        ),
        .target(
            name: "yl_player_macos",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                "YlFFmpegBridge"
            ]
        )
    ]
)
