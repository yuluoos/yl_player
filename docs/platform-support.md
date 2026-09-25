# yl_player v0.2 platform support

The endorsed implementations target Android API 24+, iOS 15+, and macOS 12+.
The tables describe route and policy decisions in `0.2.0-dev.2`; “supported”
means the implementation has an enforcement path, not that every device,
codec/profile, server, or media file will play. Run `player.assess` for the
actual source and requirements before Load.

## Route matrix

| Source or route | Android Media3 | Apple AVPlayer | Apple managed fallback |
|---|---|---|---|
| Android `content:` URI | Supported; Android only | Rejected as invalid | Rejected as invalid |
| Local MP4/MOV and platform-native progressive media | Supported subject to Media3 extractor/codec | Supported subject to AVFoundation/codec | Not selected |
| Network MP4/MOV | Supported with Media3 | Supported only without request headers or credentials | Managed request rejected |
| HLS without request metadata | Supported | Supported; VOD HEVC-in-MPEG-TS media playlists use managed demux + VideoToolbox | Managed request rejected |
| HLS with ordinary headers or credentials | Supported subject to Android origin filtering | Inspection-dependent controlled manifest/key/media-proxy route; same-origin credentials enforced | Managed request rejected |
| Static clear DASH (`dash` or `.mpd`) | Owned Media3 1.11.0 DASH route; current validation described below | Inspection-dependent private HLS adaptation for a bounded static AVC/AAC fMP4 subset | Not selected |
| Local Matroska | Supported subject to Media3 | Not selected | Inspection-dependent; supported H.264/H.265 video with AAC-LC/MP3 route |
| Network Matroska VOD | Supported subject to Media3 | Not selected | Inspection-dependent owned byte route |
| Network Matroska marked live | Media3 route; runtime-dependent | Not selected | Rejected |
| Network HTTP-FLV | Supported subject to Media3 | Not selected | Inspection-dependent sequential owned byte route |
| Plain TCP RTMP, classic AVC with optional AAC | Owned bounded transport into Media3 FLV extractor; no fallback/retry nesting | Not selected | Owned bounded transport into custom AVIO/FLV and VideoToolbox |
| RTMPS, enhanced RTMP, other RTMP codecs or audio-only RTMP | Explicitly unsupported | Not selected | Explicitly unsupported |
| Local FLV or WebM | Media3 route; runtime-dependent | Not selected | Rejected until an inspected supported route is available |
| AVI, MPEG-TS, or MPEG-PS request | Media3 route; runtime-dependent | Rejected before engine selection (`container.unsupported`, or `policy.unsupported` for a strict request) | Rejected before engine selection |
| Unknown network format | Inspection-dependent | Inspection-dependent | Apple inspection reads at most the bounded 4096-byte signature window, then reassesses |

The Apple FFmpeg artifact enables Matroska, FLV, MP4, and MPEG-TS demuxing plus the
documented parsers. It does not provide networking or software video decoding.
Apple managed fallback requires a supported video stream; audio-only fallback
media is currently rejected.

For non-RTMP sources with formats other than DASH, Android first tries Media3, then makes at most one managed fallback attempt for
container/extractor and decoder failures. The fallback uses package-owned local,
content, progressive HTTP, or HLS VOD/live input; FFmpeg demuxes MP4/MOV,
Matroska/WebM, FLV, and MPEG-TS. H.264/H.265 packets stay compressed for
MediaCodec when the stream's codec/profile/level has a hardware decoder. If no
compatible decoder exists, H.264/H.265 video at no more than 720p30 is software
decoded to the Flutter texture. Higher adaptive variants are downgraded when a
qualifying variant exists; otherwise Load fails. Supported fallback audio is
AAC, MP3, AC-3, E-AC-3, DTS, FLAC, Opus, and Vorbis. Standard HLS AES-128 is
supported; Widevine, SAMPLE-AES, and DRM bypass are not.

## RTMP foundation scope

RTMP accepts automatic/FLV format and automatic/live intent. It is live,
nonseekable, with unknown duration. HTTP headers/credentials, managed HTTP
networking, bounded buffering, VOD, nonzero initial position, and every runtime
`seekTo` (including zero) are rejected explicitly before unsupported work.
`seekToLiveEdge` starts a fresh live epoch. Ordinary buffer modes remain tuning
goals; this phase establishes no latency SLO or complete CAP-LIVE/REQ-08 support.

Setup has one absolute 10 s deadline; established media inactivity counts 15 s of
active read demand, suspended during consumer pause/backpressure. Media/control
messages are capped at 4 MiB/64 KiB, aggregate reassembly at 8 MiB, chunk histories at 32,
and outbound controls at 64 KiB. These engineering limits do not implement the
public bounded-buffer policy. Committed automatic recovery has one owner and
at most three attempts at 500/1000/2000 ms, without budget reset on successful frames.
Cancellation closes owned sockets and cancels pending work. Android API 24 system
DNS can outlive caller cancellation in at most two globally retained slots;
no unbounded queue or claim of OS-thread termination.

See the [RTMP stage report](superpowers/reports/2026-09-22-rtmp-foundation.md)
for the measured application matrix, independent MediaMTX peer, safe errors and
separately labeled native restoration evidence. Runtime missing-stream candidate
preservation alone does not prove post-lease rollback. Audio-track presence does
not establish audible quality, AV sync, physical/minimum-OS coverage, endurance,
or real subscription availability.

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

Package-controlled Apple HLS (including the DASH adapter) and bounded fallback temporarily cannot overlap
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

## DASH implementation boundary

`YlMediaFormat.dash` appends ordinal 10; existing format ordinals 0–9 are unchanged.
Android recognizes `.mpd` from the URI path (independent of query) and honors an
explicit DASH hint on extensionless URLs. The same Media3 1.11.0 module, owned
HTTP data source, origin graph and managed load retry policy serve manifests,
initialization/index requests and media. DASH never selects the FFmpeg fallback.
`buffer.bounded` stays rejected; hardware-required decoding retains its existing
positive-evidence requirement.

The initial parser accepts clear, static MPDs with known positive period durations.
Media3 expands finite SegmentTemplate/Timeline/List URLs; SegmentBase supports
initialization and index URLs plus byte-range media in the same representation
resource. Each BaseURL ancestor and resolved request URI is registered before
requests can consume the manifest. Cross-origin ancestry permanently strips
credentials, including return-to-origin and previously registered children;
unknown ancestry remains stripped. Ordinary headers continue to apply.

URI admission also caps each raw/resolved/normalized URI at 8,192 UTF-16 code
units and charges at most 4,194,304 URI code units per parse before graph retention.
Every registration charges both parent and child, both raw and normalized HTTP
forms, including repeated values. This conservatively bounds long-prefix × finite
segment amplification without attempting an OOM-sized input. Raw BaseURL text and
all XML attributes also have an 8,192-unit cap before Media3 expands them. Template
numeric padding is limited to 64 characters; a conservative expansion estimate
using the longest representation ID must fit the same per-URI cap before Media3
formats any template. Oversized normalized percent-escaped URLs are rejected too.

Resource admission limits are 2 MiB of MPD bytes, 4,096 representations, 128 base
URL results per inherited parent-list identity (cumulative across sibling uses),
depth 64, 100,000 XML elements,
100,000 expanded timeline elements, and 100,000 total graph registrations per
parse. Oversized repeats are rejected before expansion; each timeline element and
graph edge is also checked before allocation/registration. These limits are parser
and credential-graph limits, not a media buffer accounting claim. Dynamic MPD,
ContentProtection, unknown/unbounded indexes, XLink, Location, UTCTiming and content
steering are currently rejected as `container.unsupported`; no unlicensed or
uncontrolled fallback is attempted. Malformed XML remains a parser failure.

Android assessment and real Media3 parser/credential-policy JVM tests establish the
route and network-policy implementation. Six Android 16 / API 36 emulator
integration cases pass for the synthetic two-Period H.264/AAC fixture: actual
first-frame, program-time seek/resume/completion, request credential ancestry,
safe HTTP 403 failure, and active/pending Stop. This is a controlled fixture
result, not a general stream/device matrix; see the [implementation report](superpowers/reports/2026-09-22-dash-foundation.md). Apple
now routes explicit DASH and automatic `.mpd` network VOD to an inspected private
HLS adapter and AVPlayer. The original DASH identity is retained. Its initial
subset accepts one video AdaptationSet with up to 16 compatible AVC representations
and optional shared AAC-LC audio per Period, with at most 256 total representations
including audio. Multiple video renditions must share codec/roles and exactly
aligned segment boundaries. Every Period retains the same unambiguous ladder of
dimensions and bandwidths, matched independently of representation ID or XML order;
audio format and presence stay consistent. Singleton video retains its original
cross-Period compatibility rules. Periods remain contiguous and finite from zero,
with zero presentationTimeOffset. SegmentTemplate/Timeline and
SegmentList support bounded URL expansion, initialization and media byte ranges.
Only one BaseURL choice per level is admitted in this initial Apple subset.
Unsupported timing/numbering attributes fail closed before inheritance.

The Apple loader fetches at most 2 MiB of MPD and keeps generated playlists in a
per-session registry (2 MiB each, 4 MiB total). XML depth/elements, Period count,
segment expansion and URI retention have explicit limits documented in the
[Apple adapter plan](superpowers/plans/2026-09-22-apple-dash-adapter.md).
Virtual manifest identities are served only locally; unknown identities and
wrong resource kinds cannot reach upstream. Every real init/media request uses
the owned loopback proxy, including requests without explicit credentials.
Original source origin and sticky cross-origin ancestry govern credentials;
redirecting back to the source origin cannot restore them.

Local/live DASH, dynamic or encrypted MPD, SegmentBase, nonzero offsets, gaps or
overlaps, changing ladders, multiple video AdaptationSets, multiple audio
representations and track/codec changes remain rejected by the Apple subset.
Multi-video admission also rejects explicit unsupported color/range descriptors
in its ancestry; the adapter does not inspect arbitrary media bitstreams to prove
HDR equivalence. Managed network, bounded buffer and hardware-required requests
remain `policy.unsupported`; parser/registry budgets do not enforce those media
policies. The route does not use FFmpeg or add a commercial SDK.

Focused native tests verify Apple compiler, loader, credentials, range
requests, cancellation and restoration. Thirteen public Flutter integration
cases pass on each of macOS 27 arm64 and iOS 27 arm64 Simulator for the synthetic
two-Period AVC/AAC fixture: real first-frame output, natural Period transition,
forward/backward seek and completion, credential ancestry, failed-candidate
rollback, cancellation, safe errors and strict-policy rejection. See the [Apple implementation report](superpowers/reports/2026-09-22-apple-dash-adapter.md)
for executed evidence and limitations. Full Apple DASH coverage, DRM, full
ABR/subtitle matrices and cross-device coverage remain part of the accepted
delivery scope and are not completed here.

The subsequent compatible-ladder extension passed 45 focused compiler/loader
tests on each of macOS and iOS Simulator, and one public playback case per
platform using separately encoded 320×180 and 640×360 variants across two
reordered Periods. Both public runs selected the lower variant and verified
first frame, natural Period transition, bidirectional seeks and completion.
These runs establish consumption of a multivariant presentation, not observed
adaptive up/down switching, a strict quality ceiling or a fixed-quality API.
See the [follow-up report](superpowers/reports/2026-09-24-dash-variants-and-live-integration.md).
See [transport compatibility](transport-compatibility.md) for Android schema 4,
Apple schema 3, and mixed-version safety.

## Fixed video selection stage

The public session command `selectVideoTrack(trackId)` accepts an ID from the
current `state.videoTracks`; `selectVideoTrack(null)` explicitly returns to
automatic selection. `state.videoSelection` reports the authoritative mode and
its `initial`, `user`, or `trackUnavailable` reason. A successful command
acknowledges the selection request, while observed `videoGeometry` and playback
state establish what the decoder actually displayed. `videoTracks.isSelected`
does not by itself prove decoded pixel dimensions. Existing
`setVideoConstraints` remains an independent upper limit; an incompatible
update while fixed fails rather than silently moving the fixed selection.

Android Media3 is the first implementation of this command. It pins one
compatible AVC/SDR video track using a real Media3 track override, matches the
same quality across Periods despite representation ID or order changes, and
returns to automatic selection with `trackUnavailable` when the current Period
confirms that quality is absent. Transient empty catalogs do not by themselves
mean the quality disappeared. The conservative fixed path rejects incompatible
codec/profile, HDR, ambiguous quality identity, or an unproven host/device cap.
Apple currently reports fixed-video selection as unsupported; its existing
compatible DASH ladder remains under AVPlayer's automatic choice.

The controlled Android playback gate uses an eight-second, two-Period
320×180/640×360 AVC/AAC fixture to inspect first frame, decoded geometry,
state transitions, segment requests, timeline, seek, and Stop. Its precise
result and any remaining discrepancy are recorded in the
[fixed-selection stage report](superpowers/reports/2026-09-24-fixed-video-selection.md).
This gate does not establish full adaptive bitrate behavior, weak-network
quantitative response, HDR switching, general DASH interoperability, or a
physical/minimum-OS device matrix. Fixed Apple behavior and dynamic Apple
ladder changes remain future work.

## Optional JavaScript source resolution

`yl_player_source_resolver` is a separate development package; installing the
player does not install or execute a JavaScript runtime. It resolves a script
into a media URI and request metadata. The application owns cancellation when
changing channels, explicit refresh, and handing the result to the player.

The resolver uses the same pinned QuickJS source on Android, iOS and macOS,
with per-job native execution, deadline/cancellation and heap/stack limits.
Its HTTP host has separate request and response budgets; these are not the
player's media `buffer.bounded` policy. Caller/script headers are all treated
as credentials, with sticky removal after a cross-origin redirect.

A valid header-free resolved RTMP app/playpath URI converts to a player source
and retains live intent. RTMP results with HTTP headers are rejected; RTMPS
conversion remains explicitly unsupported. HTTP(S) conversion retains credentials
and live intent. Playback remains subject to the selected engine's route and
policy checks above. Unknown script expiry remains unknown.

The focused application matrix has 26 passing cases on each of macOS arm64,
iOS 27 arm64 Simulator and Android API 36 arm64 Emulator, including the nine
frozen scripts and matching-session AVPlayer/Media3 firstFrame. macOS evidence
combines 25 initial passes and one focused handoff rerun; iOS/Android each passed
a complete run. No physical/minimum-OS/endurance coverage is implied. See the
[resolver implementation record](superpowers/reports/2026-09-22-script-resolver.md)
for exact evidence and remaining gates. Controlled original-script
compatibility, actual media handoff and external subscription availability
are separate claims.
