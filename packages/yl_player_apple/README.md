# yl_player_apple

Shared typed iOS and macOS implementation for `yl_player`, currently endorsed
by the app-facing package on both Apple platforms. Applications should depend
on `yl_player`. The package provides the native registry, per-player Pigeon
transport, session lifecycle, AVPlayer and fallback engines, and one combined
FFmpeg bridge artifact.

Deployment floors are iOS 15.0 and macOS 12.0 for CocoaPods and Swift Package
Manager. This is a development consolidation checkpoint, not v0.2 release
readiness. Managed network, bounded buffers, and `hardwareRequired` currently
return `policy.unsupported` pending the Hardening phase. Public View composition
and presentation behavior remain owned by the View phase; broader release and
physical-device validation remain outstanding.
