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
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .binaryTarget(
            name: "YlFFmpegBridge",
            path: "Frameworks/YlFFmpegBridge.xcframework"
        ),
        .target(
            name: "yl_player_apple",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                "YlFFmpegBridge"
            ]
        )
    ]
)
