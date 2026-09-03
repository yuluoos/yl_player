# yl_player_ios

Endorsed iOS implementation package for `yl_player`.

Version `0.1.0-dev.1` provides federated Dart/Swift registration and an
idempotent compile-safe placeholder player. It targets iOS 15.0 or later, but
AVPlayer playback is **not implemented in this milestone**. Every playback
command fails with the structured code `ios.not_implemented`.

Applications should depend on `yl_player`; Flutter selects this package on iOS
automatically. Both CocoaPods and Swift Package Manager metadata declare iOS 15.
