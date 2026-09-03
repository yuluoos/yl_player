// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "yl_player_ios",
    platforms: [
        // Flutter's generated Swift-package aggregator currently declares iOS 13.
        // The app and podspec remain the authoritative iOS 15 runtime floor.
        .iOS("13.0")
    ],
    products: [
        .library(name: "yl-player-ios", targets: ["yl_player_ios"])
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
            name: "yl_player_ios",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                "YlFFmpegBridge"
            ],
            resources: [
                // If your plugin requires a privacy manifest, for example if it uses any required
                // reason APIs, update the PrivacyInfo.xcprivacy file to describe your plugin's
                // privacy impact, and then uncomment these lines. For more information, see
                // https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
                // .process("PrivacyInfo.xcprivacy"),

                // If you have other resources that need to be bundled with your plugin, refer to
                // the following instructions to add them:
                // https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package
            ]
        )
    ]
)
