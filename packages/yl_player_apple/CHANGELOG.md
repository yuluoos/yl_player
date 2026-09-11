## 0.2.0-dev.1

- Consolidate the typed registry, session lifecycle, Pigeon transport, AVPlayer
  and fallback engines into one endorsed iOS/macOS implementation.
- Share one FFmpeg XCFramework across iOS device, iOS Simulator and macOS.
- Support iOS 15.0 and macOS 12.0 through CocoaPods and Swift Package Manager.
- Preserve HLS credential stripping across same-session reconstruction and
  bound Dart session authority and event deduplication bookkeeping.
- Separate immutable artifact verification from exact-toolchain reproduction.
- Enforce managed Matroska/FLV networking, Player-wide bounded fallback budgets,
  positive VideoToolbox hardware requirements, and process-wide audio ownership.
- Add transactional replacement/recovery, controlled HLS credential routing,
  safe diagnostics, and authoritative geometry/first-frame publication.
- Add generated-callback transport size/schema invariants and publication gates.
- Remain a development checkpoint: physical-device, minimum-OS, Intel-native,
  profiling, consumer, and final release validation are still outstanding.
