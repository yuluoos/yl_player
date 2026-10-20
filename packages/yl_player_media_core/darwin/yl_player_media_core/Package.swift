// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "yl_player_media_core",
    platforms: [.iOS("15.0"), .macOS("12.0")],
    products: [
        .library(name: "yl-player-media-core", targets: ["yl_player_media_core"]),
        .library(name: "YlFFmpegBridge", targets: ["YlFFmpegBridge"])
    ],
    dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")],
    targets: [
        .binaryTarget(name: "YlFFmpegBridge", path: "Frameworks/YlFFmpegBridge.xcframework"),
        .target(name: "yl_player_media_core", dependencies: [
            .product(name: "FlutterFramework", package: "FlutterFramework"), "YlFFmpegBridge"
        ])
    ]
)
