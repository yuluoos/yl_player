# yl_player_ios

Endorsed iOS implementation package for `yl_player`.

Version `0.1.0-dev.1` provides an AVPlayer backend that renders through
`AVPlayerItemVideoOutput` directly to a Flutter Texture. It targets iOS 15.0 or
later and supports HLS, AVFoundation-compatible progressive network media, and
local files, including live-edge seeking, audio selection,
quality ceilings, structured state/errors, and idempotent resource release.

This development tree bundles experimental native fallbacks using minimized
FFmpeg demux, required-hardware VideoToolbox decode, and Apple audio rendering:
Matroska supports local and HTTP/HTTPS VOD with H.264/H.265 plus AAC-LC;
HTTP/HTTPS FLV supports non-seekable live H.264/H.265 plus AAC-LC, MP3, or no
audio. Neither fallback is a stable support claim until physical-device, memory,
and endurance acceptance is complete.

Custom HTTP headers are accepted by HLS and the package-owned MKV/FLV paths.
Header-bearing progressive AVPlayer sources are rejected with
`container.headers_require_fallback`; the package does not rely on undocumented
AVFoundation header keys. HLS manifests and AES keys use a resource loader.
Media/init resources use a short-lived proxy bound to `127.0.0.1`, since
AVFoundation rejects HLS media delivered directly from a custom scheme. The
proxy applies headers through URLSession and is cancelled with the asset.

For HLS, `Authorization`, `Cookie`, and `Proxy-Authorization` are retained only
for the top-level manifest's exact origin (scheme, normalized host, and effective
port). Automatic URLSession cookie storage is disabled, so only the caller's
explicit `Cookie` is eligible under that policy. Other headers reach same- and
cross-origin resources. Caller `Range`, `Host`, and content-length headers cannot
override package-owned transport fields. Manifests are capped at 2 MiB and
rewritten URLs are restricted to HTTP or HTTPS.

AVPlayer owns connection timeout and retry behavior for unheadered sources, so
`YlNetworkPolicy` is not enforced on that path. Header-bearing HLS applies
connect/read timeouts and `maxRedirects` in its loader/proxy; AVPlayer still owns
adaptive retry behavior. `bufferMode` selects a finite forward-buffer duration;
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

Valid HTTP 206 responses enable MKV seeking. HTTP 200 from byte zero is accepted as
sequential playback with `isSeekable=false`. Same-origin redirects retain caller
headers; cross-origin redirects strip `Authorization`, `Cookie`, and
`Proxy-Authorization`. Network MKV live, non-AAC MKV audio, subtitles, DRM, and
non-HTTP transports remain unsupported.

HTTP-FLV always starts at byte zero, never sends Range, reports live and
non-seekable state, and reconstructs demux, hardware decode, audio, queues, and
clocks after a disconnect. Retries use the configured bounded count/base/max
delay and emit `YlRetryEvent`; exhaustion is `network.retry_exhausted`. Sorenson
H.263, VP6, AV1, VP9, Nellymoser, Speex, audio-only FLV, and DVR are unsupported.

HTTPS uses the host application's normal ATS trust policy. Header-bearing HLS
also requires the host to permit local networking (for example with
`NSAllowsLocalNetworking`) for the loopback media proxy. Remote cleartext HTTP
requires a minimal, preferably domain-scoped ATS exception; this plugin does not
add a global ATS relaxation.

Applications should depend on `yl_player`; Flutter selects this package on iOS
automatically. Both CocoaPods and Swift Package Manager metadata declare iOS 15.

Automated Simulator gates cover routing, HTTP policy, HLS header-origin behavior,
AES-128 playback, bounded memory, cancellation, lifecycle, and loopback HTTP
integration. Simulator FLV may return the exact hardware-unavailable error.
Production HTTPS/TLS and target-device H.264/AAC, H.264/MP3, H.265/AAC,
reconnect, memory-warning, and 30-minute evidence remain required before a stable
HTTP-FLV claim.
