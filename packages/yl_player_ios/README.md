# yl_player_ios

Endorsed iOS implementation package for `yl_player`.

Version `0.1.0-dev.1` provides an AVPlayer backend that renders through
`AVPlayerItemVideoOutput` directly to a Flutter Texture. It targets iOS 15.0 or
later and supports HLS, AVFoundation-compatible progressive network media, and
local files, including request headers, live-edge seeking, audio selection,
quality ceilings, structured state/errors, and idempotent resource release.

HTTP-FLV and containers outside AVFoundation are deliberately rejected with
`container.http_flv_requires_fallback`. The planned libavformat + VideoToolbox
fallback is not bundled in this development release.

Applications should depend on `yl_player`; Flutter selects this package on iOS
automatically. Both CocoaPods and Swift Package Manager metadata declare iOS 15.

Decoder behavior and smoothness must be verified against the target iPhone/iPad
and production stream matrix before a stable release.
