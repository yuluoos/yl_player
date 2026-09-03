# yl_player_ios

Endorsed iOS implementation package for `yl_player`.

Version `0.1.0-dev.1` provides an AVPlayer backend that renders through
`AVPlayerItemVideoOutput` directly to a Flutter Texture. It targets iOS 15.0 or
later and supports HLS, AVFoundation-compatible progressive network media, and
local files, including live-edge seeking, audio selection,
quality ceilings, structured state/errors, and idempotent resource release.

HTTP-FLV and remote containers outside AVFoundation are deliberately rejected
with `container.native_fallback_required`. This development tree bundles an
experimental local-only Matroska fallback using minimized FFmpeg demux,
required-hardware VideoToolbox decode, and native AAC rendering. It is limited
to H.264/H.265 + AAC and is not a support claim until physical-device and memory
acceptance is complete.

Sources requiring custom HTTP headers are likewise rejected with
`container.headers_require_fallback`; this package does not rely on undocumented
AVFoundation header keys.

AVPlayer owns connection timeout and retry behavior, so `YlNetworkPolicy` is not
enforced on this main path. `bufferMode` selects a finite forward-buffer duration;
custom min/max duration and byte ceilings are not enforceable through AVPlayer.
`decoderPolicy` remains hardware-first under AVFoundation but cannot force or
identify a concrete decoder. The local Matroska fallback requires VideoToolbox
hardware and returns `decoder.video_hardware_unavailable` when unavailable.

Applications should depend on `yl_player`; Flutter selects this package on iOS
automatically. Both CocoaPods and Swift Package Manager metadata declare iOS 15.

Decoder behavior and smoothness must be verified against the target iPhone/iPad
and production stream matrix before a stable release.
