# yl_player v0.2 platform support

The endorsed implementations target Android API 24+, iOS 15+, and macOS 12+.
The tables describe route and policy decisions in `0.2.0-dev.1`; “supported”
means the implementation has an enforcement path, not that every device,
codec/profile, server, or media file will play. Run `player.assess` for the
actual source and requirements before Load.

## Route matrix

| Source or route | Android Media3 | Apple AVPlayer | Apple managed fallback |
|---|---|---|---|
| Android `content:` URI | Supported; Android only | Rejected as invalid | Rejected as invalid |
| Local MP4/MOV and platform-native progressive media | Supported subject to Media3 extractor/codec | Supported subject to AVFoundation/codec | Not selected |
| Network MP4/MOV | Supported with Media3 | Supported only without request headers or credentials | Managed request rejected |
| HLS without request metadata | Supported | Supported | Managed request rejected |
| HLS with ordinary headers or credentials | Supported subject to Android origin filtering | Inspection-dependent controlled manifest/key/media-proxy route; same-origin credentials enforced | Managed request rejected |
| Local Matroska | Supported subject to Media3 | Not selected | Inspection-dependent; supported H.264/H.265 video with AAC-LC/MP3 route |
| Network Matroska VOD | Supported subject to Media3 | Not selected | Inspection-dependent owned byte route |
| Network Matroska marked live | Media3 route; runtime-dependent | Not selected | Rejected |
| Network HTTP-FLV | Supported subject to Media3 | Not selected | Inspection-dependent sequential owned byte route |
| Local FLV or WebM | Media3 route; runtime-dependent | Not selected | Rejected until an inspected supported route is available |
| AVI, MPEG-TS, or MPEG-PS request | Media3 route; runtime-dependent | Rejected before engine selection (`container.unsupported`, or `policy.unsupported` for a strict request) | Rejected before engine selection |
| Unknown network format | Inspection-dependent | Inspection-dependent | Apple inspection reads at most the bounded 4096-byte signature window, then reassesses |

The Apple FFmpeg artifact enables only Matroska and FLV demuxing plus the
documented parsers. It does not provide networking or software video decoding.
Apple managed fallback requires a supported video stream; audio-only fallback
media is currently rejected.

## Policy matrix

| Requirement | Android Media3 | Apple AVPlayer | Apple managed fallback |
|---|---|---|---|
| `network.platformDefault` | Supported; exact system behavior is opaque | Supported where the selected route can enforce credential origin rules | Supported on owned byte routes |
| `network.managed` | Supported by the Android managed Media3 data-source policy | Rejected | Supported only for network Matroska/FLV after route/inspection checks |
| `buffer.automatic`, `lowLatency`, `smoothPlayback` | Supported as tuning goals | Supported as tuning goals | Supported as tuning goals |
| `buffer.bounded` | Rejected | Rejected | Supported subject to codec/timing inspection and Player-wide ledger admission |
| `decoder.systemDefault` | Supported; actual decoder mode reported | Supported; decoder mode remains unknown | Supported; measured mode reported |
| `decoder.hardwarePreferred` | Supported with fallback candidates retained | Supported but decoder mode remains unknown | Supported with truthful hardware/software/unknown result |
| `decoder.hardwareRequired` for video | Inspection-dependent until initialized MediaCodec proves hardware | Rejected because positive evidence is unavailable | Inspection-dependent; positive VideoToolbox evidence required before commit |
| `audio.appManaged` | Supported; application owns focus | Supported; application owns audio session/category | Supported; application owns audio policy |
| `audio.pluginManagedMediaPlayback` | Supported with one plugin focus owner | Supported with process-wide Apple leases | Supported with the same Apple ownership lease |

Package-controlled Apple HLS and bounded fallback temporarily cannot overlap
while either route still owns payload or completion state. The candidate is
rejected and accepted playback is preserved. See [policy semantics](policies.md)
for exact networking, buffer, decoder, and audio behavior.

## Evidence status

Automated implementation evidence includes Dart lifecycle/adapter tests,
Android JVM policy tests, Swift native policy and lifecycle tests, selected iOS
Simulator and native macOS runtime cases, controlled VideoToolbox tests, and
focused public Flutter cases. Selected local TLS fixtures prove encrypted
transfer plus chain/hostname rejection under isolated test trust; they do not
prove a production publicly trusted server path.

The current focused Apple evidence includes actual macOS hardware-decoder
commit on covered fixtures. An iOS Simulator may skip the one real bounded H.264
case only when the inspected stream is H.264 and VideoToolbox explicitly reports
hardware decode unavailable; controlled hardware-path tests still execute. A
Simulator skip or controlled decoder output is not physical-device evidence.

Still pending final acceptance: physical iOS hardware playback, Android
7/1.5-GB/32-bit endurance, minimum-OS runtime matrices, native Intel macOS
decoding, Instruments/memgraph profiling, full consumer/package-manager
matrices, remote CI, and the complete canonical regression/release matrix.
