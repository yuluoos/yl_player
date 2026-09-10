# yl_player_apple

Shared endorsed iOS and macOS implementation for `yl_player` 0.2. Applications
should depend on `yl_player`; Flutter registers this package on both Apple
platforms. Deployment floors are iOS 15.0 and macOS 12.0 for CocoaPods and Swift
Package Manager.

The package contains one typed registry/session lifecycle, AVPlayer routes,
controlled HLS loading, managed Matroska/FLV fallback, VideoToolbox and
AudioToolbox output, and one combined FFmpeg bridge XCFramework. AVPlayer handles
HLS and native progressive media where policy permits. Package-owned fallback
handles inspected Matroska and network FLV with the codec and timing limits in
the [support matrix](../../docs/platform-support.md).

Apple managed networking is available only on the owned Matroska/FLV byte
routes. Bounded buffering uses one Player-wide assigned-byte ledger and is
available only on the managed fallback. Hardware-required video needs positive
VideoToolbox evidence before commit; AVPlayer cannot supply that evidence.
Plugin-managed audio uses process-wide ownership leases, with iOS media-playback
session/category management and macOS no-global-session behavior. See
[policy semantics](../../docs/policies.md) for enforcement and transition
restrictions.

The combined XCFramework contains iOS device, iOS Simulator, and universal
macOS slices. It uses FFmpeg 9.0.1 only for Matroska/FLV demuxing and packet
parsing; networking and video/audio decode remain package/system owned. Binary
redistributors must keep `THIRD_PARTY_NOTICES.md`,
`LICENSES/FFmpeg-LGPL-2.1-or-later.txt`, the artifact lock, and replacement
scripts. The notice documents verification and exact-toolchain rebuild flows.

Focused native and Flutter evidence exists for iOS Simulator and native macOS,
including strict-policy rejection and controlled hardware paths. Physical iOS,
minimum-OS, native Intel decoding, endurance, profiling, full consumer, and
release matrices remain pending final acceptance.
