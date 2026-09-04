# yl_player_ios

Endorsed iOS implementation package for `yl_player`.

Version `0.1.0-dev.1` provides an AVPlayer backend that renders through
`AVPlayerItemVideoOutput` directly to a Flutter Texture. It targets iOS 15.0 or
later and supports HLS, AVFoundation-compatible progressive network media, and
local files, including live-edge seeking, audio selection,
quality ceilings, structured state/errors, and idempotent resource release.

HTTP-FLV and remote containers outside the implemented boundary are deliberately
rejected with structured fallback errors. This development tree bundles an
experimental Matroska fallback for local files and HTTP/HTTPS VOD using minimized
FFmpeg demux, required-hardware VideoToolbox decode, and native AAC-LC rendering.
It is limited to H.264/H.265 video plus zero or more AAC tracks and is not a
stable support claim until physical-device and memory acceptance is complete.

Custom HTTP headers are accepted only by the network Matroska fallback. Other
AVPlayer-routed sources requiring headers are rejected with
`container.headers_require_fallback`; the package does not rely on undocumented
AVFoundation header keys.

AVPlayer owns connection timeout and retry behavior, so `YlNetworkPolicy` is not
enforced on this main path. `bufferMode` selects a finite forward-buffer duration;
custom min/max duration and byte ceilings are not enforceable through AVPlayer.
`decoderPolicy` remains hardware-first under AVFoundation but cannot force or
identify a concrete decoder. Both local and network Matroska require VideoToolbox
hardware and return `decoder.video_hardware_unavailable` when unavailable.

The HTTP/HTTPS Matroska path uses `URLSession` with FFmpeg custom AVIO; FFmpeg's
own networking and TLS remain disabled. Network cache ceilings are 4 MiB for
`lowLatency`, 8 MiB for `automatic`/`balanced`, and 16 MiB for `stable`. In
`custom`, `maxBufferBytes` is divided across network bytes, scheduled PCM, and
one in-flight encoded packet and must be at least 3 MiB. Memory warnings shrink
the network cache to 2 MiB until foreground reconstruction. No persistent cache
is created.

Valid HTTP 206 responses enable seeking. HTTP 200 from byte zero is accepted as
sequential playback with `isSeekable=false`. Same-origin redirects retain caller
headers; cross-origin redirects strip `Authorization`, `Cookie`, and
`Proxy-Authorization`. Network MKV live, HTTP-FLV fallback, non-AAC audio,
subtitles, DRM, and non-HTTP transports remain unsupported.

HTTPS uses the host application's normal ATS trust policy. Remote cleartext HTTP
requires the host to allow the destination with its own minimal, preferably
domain-scoped ATS exception; this plugin does not add a global ATS relaxation.

Applications should depend on `yl_player`; Flutter selects this package on iOS
automatically. Both CocoaPods and Swift Package Manager metadata declare iOS 15.

Automated Simulator gates cover routing, HTTP policy, bounded memory,
cancellation, lifecycle, and loopback HTTP integration behavior. Production
HTTPS/TLS, decoder behavior, memory, and smoothness must still be verified
against the target iPhone/iPad and production stream matrix before a stable
release.
