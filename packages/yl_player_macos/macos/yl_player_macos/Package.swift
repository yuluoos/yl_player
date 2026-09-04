// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "yl_player_macos",
    platforms: [
        // Flutter's generated Swift-package aggregator currently declares
        // macOS 10.15. The app and podspec are authoritative for macOS 12.
        .macOS("10.15")
    ],
    products: [
        .library(name: "yl-player-macos", targets: ["yl_player_macos"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "yl_player_macos",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
