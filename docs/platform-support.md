# yl_player v0.2 platform support

The endorsed implementations target Android API 24+, iOS 15+, and macOS 12+.
The tables describe route and policy decisions in `0.3.0-dev.1`; “supported”
means the implementation has an enforcement path, not that every device,
codec/profile, server, or media file will play. Run `player.assess` for the
actual source and requirements before Load.

## Route matrix

| Source or route | Android route | Apple AVPlayer | Apple managed fallback |
|---|---|---|---|
| Android `content:` URI | Supported; Android only | Rejected as invalid | Rejected as invalid |
| Local MP4/MOV and platform-native progressive media | Supported subject to Media3 extractor/codec | Default route, subject to AVFoundation/codec | MP4/MOV use owned samples for strict policy requests; other native formats retain their prior route |
| Network MP4/MOV | Supported with Media3 | Default route without request headers or credentials | VOD with request headers/credentials, managed networking, bounded buffering or hardwareRequired uses owned samples after inspection |
| HLS without request metadata | Supported | Supported; VOD HEVC-in-MPEG-TS media playlists use managed demux + VideoToolbox | Managed request rejected |
| HLS with ordinary headers or credentials | Supported subject to Android origin filtering | Inspection-dependent controlled manifest/key/media-proxy route; same-origin credentials enforced | Managed request rejected |
| Static clear DASH (`dash` or `.mpd`) | Owned Media3 1.11.0 DASH route; current validation described below | Retained private HLS adapter for its compatible subset | Owned sample programme route for admitted static AVC/HEVC/AAC fMP4 |
| Local Matroska | Supported subject to Media3 | Not selected | Inspection-dependent; supported H.264/H.265 video with supported compressed audio; FLAC scope below |
| Network Matroska VOD | Supported subject to Media3 | Not selected | Inspection-dependent owned byte route |
| Network Matroska marked live | Media3 route; runtime-dependent | Not selected | Rejected |
| Network HTTP-FLV | Owned demux for explicit onDemand; automatic/live retain Media3 | Not selected | Inspection-dependent; automatic/live use sequential input, explicit onDemand supports VOD with seekability determined by HTTP Range |
| Plain TCP RTMP, classic AVC with optional AAC | Owned bounded transport into Media3 FLV extractor; no fallback/retry nesting | Not selected | Owned bounded transport into custom AVIO/FLV and VideoToolbox |
| RTMPS, classic AVC with optional AAC | Explicitly unsupported | Not selected directly; opt-in AirPlay remux available | Owned RTMP transport over authenticated TLS, system trust/hostname validation |
| Enhanced RTMP, other RTMP codecs or audio-only RTMP | Explicitly unsupported | Not selected | Explicitly unsupported |
| Local FLV | Owned demux for VOD seek | Not selected | Inspection-dependent VOD; AVC/MP3 lifecycle measured on macOS |
| Local WebM | Media3 with observed decoder admission | Not selected | Inspected VP9 with Opus/Vorbis; native hardware first, exact software admission when qualified |
| Standalone MPEG-TS VOD | Media3 route; runtime-dependent | Not selected | Inspection-dependent defaults; 188-byte AVC/AC-3 file/HTTP/renamed-file scope; strict policies use owned samples, live intent rejected |
| AVI VOD | Owned demux with verified Baseline AVC timing | Not selected | Inspection-dependent defaults; Baseline AVC/MP3 scope below; strict policies use owned samples, live intent rejected |
| MPEG-PS VOD | Owned demux for AVC/MP3; MPEG-2 video diagnostic remains unsupported | Not selected | Owned AVC/MP3 including strict policies; live intent rejected explicitly |
| Unknown network format | Inspection-dependent | Inspection-dependent | Apple inspection reads at most the bounded 4096-byte signature window, then reassesses |

The Apple FFmpeg artifact enables Matroska, FLV, MP4, MPEG-TS, MPEG-PS and AVI
demuxing plus the documented parsers. It has no networking. Its controlled AV1
(dav1d) and VP9 software candidates require an exact qualified device/build
profile and a shared resource lease. Production software profiles remain empty;
linking the decoders does not enable an unmeasured software fallback.
Apple RTMPS uses port 443 by default and accepts explicit valid ports. TLS 1.2+
and certificate/hostname validation are required; TLS failures are terminal
`network.rtmp_tls_failed` with no plaintext downgrade. Ordinary RTMP policy,
codec, seek and recovery constraints also apply to RTMPS. See
[AirPlay support](airplay.md) for its separate opt-in path and
[RTMPS verification](verification/2026-10-19-rtmps.md) for test scope.
Apple managed fallback requires a supported video stream; audio-only fallback
media is currently rejected.

Apple managed fallback now passes inspected FLAC STREAMINFO to the system audio
converter for 16/24-bit mono/stereo. On Apple M1/macOS 27, two 48 kHz owned
fixtures have independent sample-by-sample PCM verification, including short
final frames and reset; the AVC/FLAC MKV file, HTTP, and renamed-file paths pass
forward/backward seek and completion. Other bit depths and surround remain
explicitly unsupported. Physical audio output, AV sync, iOS/Intel/minimum-OS
runtime and other formats remain unverified; this does not claim complete
CAP-FORMAT acceptance. See the [P03 report](superpowers/reports/2026-09-26-remaining-03-formats-decoding.md).

Standalone Apple MPEG-TS uses a relative timeline shared by audio and video.
Seek searches for a prior decodable keyframe with lookbacks of 1, 2, 4 and
8 seconds, at most 512 demuxed packets / 8 MiB per attempt; no anchor yields
`container.mpegts_seek_failed`. These search guards are not resource/performance
acceptance. HTTP seekability depends on actual Range support. Explicit live,
managed networking, bounded buffering and hardwareRequired remain rejected.
192/204-byte packet signatures have detection tests only, not playback acceptance.
Physical output/sync, other codecs, devices and platforms remain unverified.

AVI fallback reuses the existing compressed video/audio decoders. Missing video
PTS can use DTS only for Baseline/Constrained Baseline AVC with zero reported
reorder delay; other missing-timestamp layouts fail explicitly. AVI uses the
same bounded keyframe search limits as standalone TS. The owned Baseline AVC/MP3
fixture and its local idx1-removed variant define this increment's runtime scope;
other AVI codecs/profiles, OpenDML/multipart files and physical output need
separate acceptance. Explicit live and strict policies remain rejected.

For non-RTMP sources with formats other than DASH, Android first tries Media3, then makes at most one managed fallback attempt for
container/extractor and decoder failures. The fallback uses package-owned local,
content, progressive HTTP, or HLS VOD/live input; FFmpeg demuxes MP4/MOV,
Matroska/WebM, FLV, MPEG-TS, MPEG-PS and AVI. H.264/H.265 packets stay compressed
for MediaCodec when the codec/profile/level has a proven hardware decoder. An
owned software candidate requires an exact qualified profile and shared memory,
frame, packet and process-CPU accounting. Production profiles remain empty, so
missing hardware produces an explicit decoder failure without silently changing
quality. Opaque system software codecs cannot bypass the owned budget. Supported fallback audio is
AAC, MP3, AC-3, E-AC-3, DTS, FLAC, Opus, and Vorbis. Standard HLS AES-128 is
supported; Widevine, SAMPLE-AES, and DRM bypass are not.

## Controlled weak-network/live observations (2026-10-19)

The owned AVC/AAC test subset has Android and macOS DASH auto/caps/fixed
captures with actual request and public output-geometry observations. Both
platforms completed HLS, HTTP-FLV and RTMP smooth/low/smooth lifecycle tests,
including paused intent, source replacement and stop fencing. Low-latency RTMP
also passed three lifetime recoveries followed by terminal fourth-drop failure.
iOS Simulator HLS passed 16 rapid mode pairs after an admission-order fix.
A connected iPhone completed the three-protocol lifecycle subset; HTTP-FLV and
RTMP mode replacement now hand off the exclusive decoder before construction.
iPhone RTMP also passed the bounded recovery sequence. iOS Simulator DASH caps
and fixed captures preserved their constraints. Auto downshift was observed, but
recovery upshift was absent in both 40s and extended 80s captures and remains an
open acceptance item.
A subsequent iPhone regression reproduced an expired HLS seekable window after
pausing. Low-latency direct HLS now refreshes that window using the existing
bounded retry budget; successful frames retain spent refresh attempts. Two
resumes passed, and a fourth refresh was rejected while playback stayed paused.
The user confirmed basic moving picture/audio, pause and resume for all three
protocols. This subjective check does not measure A/V synchronization.
These are specific controlled observations, not complete CAP-ABR/CAP-LIVE,
physical A/V, minimum-OS, long-play or P08 SLO qualification. See the
[P04 stage report](superpowers/reports/2026-09-26-remaining-04-abr-live.md).

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
| `network.managed` | Supported by the Android managed Media3 data-source policy | Rejected | Supported for admitted network Matroska/FLV and clear DASH programme routes after inspection |
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

### Exact programme route (P01)

Clear, static HTTP(S) DASH uses one programme timeline across Periods. Apple
retains its legacy HLS adapter for the subset below and uses the owned sample
backend when independent timing, clipping, reconfiguration or explicit managed
policies require it. Android composes declared Period windows around Media3 and
keeps decoded PCM and video visibility inside those windows. No production
remux or whole-programme download is used.

| Admitted capability | Android | iOS / macOS |
| --- | --- | --- |
| Independent audio/video PTO; non-integer microsecond boundaries | Exact declaration model; Media3/public clock projection at boundaries | Checked rational sample-to-programme mapping |
| Cropped Period endpoint; explicit gap/overlap | PCM clipping/silence; declared programme windows; video-gap clearing | Sample/PCM clipping; silence; output clearing; later Period owns overlap |
| Unknown middle duration | Adjacent start or agreeing finite AV timeline/list evidence; SegmentBase needs declared/adjacent duration | Adjacent start or agreeing finite AV references, including resolved sidx; ambiguous/unbounded duration rejected |
| Multiple BaseURL with managed networking | Declared order; one HTTP-call retry/redirect budget; sticky stripping | Ordered logical resources with shared budgets and cancellation |
| Same-SDR AVC → HEVC and resolution changes | Actual decoder output and compatible-family selection | Transactional decoder/audio/output preparation and commit |
| Audio addition/removal and explicit intent | Semantic identity survives Period/restore; missing explicit content fails | Same content intent; failed candidate cannot replace accepted selection |
| MPD VTT/TTML/wvtt/stpp | Managed discovery/selection, programme cues, actual Flutter composition | Same Dart runtime; actual native-window plus Flutter composition |

Automatic video selection stays inside compatible HDR/SDR/Dolby families.
The accepted Apple family survives background deactivation and pipeline-free
completion/end seeks. Only a successful candidate commit updates it; failed
preparation preserves the accepted family.
Unsupported Dolby paths reject explicitly; full FEL information is preserved and
this route does not silently fall back to the base layer. This is not a claim
that every P03 codec or Dolby display path is implemented. A missing fixed video
track follows PD-01 (automatic selection with independent caps retained).

Text subtitles require the existing opt-in runtime and discovery/selection APIs.
Subtitle errors are command-scoped and video continues. Valid cues survive a
video-only gap; with no current video aperture they use the bounded view area.
Explicit `dash` works for extensionless URLs; automatic admission requires the
`.mpd` URI path. Static admission does not imply live/dynamic or encrypted DASH.

Managed candidate switching does not concatenate bodies from different origins.
After response acquisition, validated body resume stays on that entity/URL.
Android rejects conflicting ordered candidate groups sharing a bare HTTP URL,
rather than guessing resource identity. Existing graph/URI/resource limits apply.

See the [P01 execution report](superpowers/reports/2026-09-26-remaining-01-dash.md)
for exact source/media hashes and separate native, compositor, PCM and lifecycle
evidence. Native consumption clocks and simulator screenshots are not physical
speaker/display measurements. Minimum-target compilation and current-OS execution
are separate from minimum-OS or missing-device runtime certification.

### Android admission and retained network limits

`YlMediaFormat.dash` appends ordinal 10; existing format ordinals 0–9 are unchanged.
Android recognizes `.mpd` from the URI path (independent of query) and honors an
explicit DASH hint on extensionless URLs. The same Media3 1.11.0 module, owned
HTTP data source, origin graph and managed load retry policy serve manifests,
initialization/index requests and media. DASH never selects the FFmpeg fallback.
`buffer.bounded` stays rejected; hardware-required decoding retains its existing
positive-evidence requirement.

The parser accepts clear, static MPDs whose positive Period windows are explicit
or determinable from authoritative adjacent starts or agreeing finite evidence.
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
result, not a general stream/device matrix; see the [implementation report](superpowers/reports/2026-09-22-dash-foundation.md).

### Retained Apple HLS-adapter subset

The legacy adapter routes explicit DASH and automatic `.mpd` network VOD to an inspected private
HLS adapter and AVPlayer. The original DASH identity is retained. Its initial
subset accepts one video AdaptationSet with up to 16 compatible AVC representations
and up to 16 AAC-LC audio AdaptationSets per Period (one Representation each),
with at most 256 total representations
including audio. Multiple video renditions must share codec/roles and exactly
aligned segment boundaries. The original identical-ladder and singleton routes
remain supported. The automatic route also accepts compatible ladders that add
or remove qualities between Periods, including disjoint high-only and low-only
Periods. It maps at most 16 distinct `(width,height,bandwidth)` identities to
bounded complete-program paths, independent of representation ID or XML order;
this mapping is neither a fixed selection nor a quality ceiling. The changing
route requires the same declared AVC codec/Profile and role, equal display
ratio, consistent normalized frame rate, absent or 1:1 SAR, and, when present,
a compatible complete AAC audio identity set with consistent presence. It rejects declared color/range,
SupplementalProperty and unsupported high-bit-depth profiles. These are MPD
declaration checks, not inspection of arbitrary encoded media bytes. Periods
remain contiguous and finite from zero. The aligned-offset extension below
also accepts a bounded nonzero presentationTimeOffset subset.
SegmentTemplate/Timeline and
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

Apple also accepts a bounded static AVC/AAC `SegmentBase` subset: an explicit
`Initialization range`, one exact `indexRange` containing a flat sidx v0/v1,
positive references with SAP type 1 and zero SAP delta, declared finite Period
duration, exact full-Period coverage, and EPT aligned with PTO across tracks.
Inherited addressing and sticky BaseURL credentials use the same admission rules.
Index requests require exact HTTP 206/Content-Range, identity encoding and exact
body length; HTTP 200 whole-file fallback and nested indexes are rejected.
Per-index input is capped at 1 MiB, all indexes at 4 MiB, with a shared 100,000
reference budget and the existing preflight deadline/cancellation. Accepted index
snapshots are immutable and reused during quality reprojection. See the
[P01 report](superpowers/reports/2026-09-26-remaining-01-dash.md) for device evidence
and remaining general DASH gaps; this is not arbitrary SegmentBase support.

Exact integer-microsecond duration conversion reduces rational factors before
checked multiplication. Large MPD clocks whose final values fit Int64 therefore
no longer fail solely because an intermediate product overflows. Fractional
microsecond Period endpoints remain rejected; this does not add independent
A/V offsets, endpoint cropping or gap/overlap support. The P01 report separates
offline decoded markers, direct HLS experiments and public player evidence.

For this legacy HLS adapter, local/live DASH, dynamic or encrypted MPD, unsupported SegmentBase forms, unaligned or independently shifted rendition offsets, gaps or
overlaps, incompatible changing ladders, multiple video AdaptationSets, multiple
audio Representations within one AdaptationSet and audio identity/codec changes
remain rejected by the Apple subset.
Managed network, bounded buffer and hardware-required requests
remain `policy.unsupported`; parser/registry budgets do not enforce those media
policies. The route does not use FFmpeg or add a commercial SDK.

Focused native tests verify Apple compiler, loader, credentials, range
requests, cancellation and restoration. Thirteen public Flutter integration
cases pass on each of macOS 27 arm64 and iOS 27 arm64 Simulator for the synthetic
two-Period AVC/AAC fixture: real first-frame output, natural Period transition,
forward/backward seek and completion, credential ancestry, failed-candidate
rollback, cancellation, safe errors and strict-policy rejection. See the [Apple implementation report](superpowers/reports/2026-09-22-apple-dash-adapter.md)
for the historical adapter evidence and limitations. The exact programme route
above extends that baseline; DRM, weak-network ABR and broader device coverage
are separate from the P01 programme measurements.

The subsequent compatible-ladder extension passed 45 focused compiler/loader
tests on each of macOS and iOS Simulator, and one public playback case per
platform using separately encoded 320×180 and 640×360 variants across two
reordered Periods. Both public runs selected the lower variant and verified
first frame, natural Period transition, bidirectional seeks and completion.
These runs establish consumption of a multivariant presentation, not observed
adaptive up/down switching, a strict quality ceiling or a fixed-quality API.
See the [follow-up report](superpowers/reports/2026-09-24-dash-variants-and-live-integration.md).
The later changing-ladder compiler gate adds complete automatic program paths
for compatible additions/removals. Its focused native evidence is 55/55
(37 compiler, 18 loader) on each Apple platform before the duplicate-identity
review fix, followed by three targeted compiler passes per platform for that
fix. These are separate runs, not a 56-test full rerun. The public playback
evidence and its precise limits are in the [changing-ladders report](superpowers/reports/2026-09-24-apple-dash-changing-ladders.md).
See [transport compatibility](transport-compatibility.md) for Android schema 5 (DRM bridge),
Apple schema 4 in the fixed-selection stage, and mixed-version safety. The
earlier Apple adapter and caps reports describe the schema at their own dates.

## Apple DASH finite final-Period duration

If static MPD and final Period timing do not declare an end, the supported
AVC/AAC adapter can derive it from finite inherited SegmentTimelines only when
all original representations have the same exact positive microsecond duration.
Declared boundaries remain authoritative; existing full-segment/common-origin
checks remain. Unknown middle boundaries, duration-only addressing, unbounded
final repeats and divergent track tails are rejected. This is a bounded
compatibility fallback, outside DASH-IF's restricted explicit-final-duration
profile. See [duration verification](superpowers/reports/2026-09-26-apple-dash-inferred-duration.md)
for executed evidence and limits; it is not general unknown-duration DASH support.

## Apple DASH single-file SegmentList references

Within the existing clear static AVC/AAC fMP4 subset, SegmentList Initialization
`sourceURL` and SegmentURL `media` may be omitted or empty. They resolve to the
effective inherited BaseURL, retaining queries, declared byte ranges, URI budgets
and sticky credential stripping. Explicit nonempty references keep their existing
behavior. This permits one file per rendition/Period with initialization and media
selected by byte ranges; that earlier slice did not add SegmentBase or sidx index discovery. The bounded indexed subset described below was added separately.
The final redirected document URL is the base when no BaseURL is declared;
resolution alone does not prove its bytes are playable media.

See the [single-file verification report](superpowers/reports/2026-09-26-apple-dash-single-file.md)
for executed native/public playback evidence and limits. General DASH, DRM,
minimum OS/physical-device behavior and measured lip-sync remain separate work.

## Apple DASH aligned presentation offsets

The clear static AVC/AAC subset accepts nonnegative integer
`presentationTimeOffset` in SegmentTemplate or SegmentList with an explicit
SegmentTimeline. Its first segment must start exactly at the offset, subsequent
segments must be contiguous, and complete segments must end exactly at offset
plus Period duration. An omitted first `S@t` still means zero. `$Time$` URLs keep
the original sample timestamp; program position is relative to the Period.

All original video candidates and the shared audio within a Period must have
the same offset/time-scale ratio. Different timescales are compared exactly;
caps/fixed selection cannot hide an incompatible origin. The common origin may
change in a later Period. Production forwards original media bytes and uses the
existing HLS discontinuity path; it does not rewrite fragment timestamps.

Nonzero offsets without a timeline, partial-segment clipping, gaps/overlaps,
independently shifted audio/video and overflowing/unbounded timing remain
unsupported. This extends the earlier zero-offset subset; it is not generic
DASH editorial timing support. Controlled playback covers real shifted tfdt/sidx
fragments, natural transitions, seeks, fixed/automatic selection, runtime caps
and rejected-candidate rollback. It does not measure audio/video synchronization
error. See the [offset-stage report](superpowers/reports/2026-09-26-apple-dash-offsets.md)
for exact platform results and limits.

## Apple DASH admission diagnostics

The bounded Apple DASH adapter distinguishes five known preflight failures:

| Code | Meaning and next step |
|---|---|
| `container.dash_manifest_invalid` | Input is not valid UTF-8 or cannot be parsed as XML. Ask the provider for a valid UTF-8 MPD. |
| `container.dash_dynamic_unsupported` | The parsed MPD declares `type="dynamic"`. Choose a static DASH VOD source for this path. |
| `container.dash_protection_unsupported` | A DASH `ContentProtection` declaration was encountered. This path cannot accept it; this is not a license-service diagnosis. |
| `container.dash_segment_base_unsupported` | A DASH `SegmentBase` declaration cannot be resolved by the bounded indexed path (for example, missing indexRange or initialization). Use a compatible indexed source or SegmentTemplate/SegmentList presentation. |
| `resource.dash_manifest_too_large` | MPD input exceeds the existing 2 MiB byte limit, including declared or streamed response size. Ask for a smaller MPD. |

These are nonretryable failures with fixed safe guidance and diagnostic IDs.
They preserve failed-candidate rollback and do not add format or DRM support.
Other unsupported structures, namespaces, DTD/entity restrictions and resource
budgets keep `container.unsupported`; an unsupported declaration is not
necessarily malformed XML. If several problems exist, the first detected
admission failure is reported, not an exhaustive MPD validation report.

Consumers that previously matched only `container.unsupported` should include
these more specific codes or handle the failure category. No wire-schema change
is required; older Dart adapters can retain the code but show generic guidance.
The evidence and limits are recorded in the
[diagnostics report](superpowers/reports/2026-09-26-apple-dash-diagnostics.md).

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
Apple implements fixed selection for its admitted static clear AVC/AAC DASH
subset. It projects the chosen quality into every containing Period's media
paths while retaining the complete allowed catalog. An absent quality in the
confirmed current Period returns to sticky automatic selection with
`trackUnavailable`; a later seek back does not reselect it. An unknown or
ambiguous ID and incompatible source are rejected with a safe command error.

The controlled Android playback gate uses an eight-second, two-Period
320×180/640×360 AVC/AAC fixture to inspect first frame, decoded geometry,
state transitions, segment requests, timeline, seek, and Stop. Its precise
result and any remaining discrepancy are recorded in the
[fixed-selection stage report](superpowers/reports/2026-09-24-fixed-video-selection.md).
This gate does not establish full adaptive bitrate behavior, weak-network
quantitative response, HDR switching, general DASH interoperability, or a
physical/minimum-OS device matrix. Apple fixed selection's own native and
public evidence is in the [Apple fixed-selection report](superpowers/reports/2026-09-26-apple-dash-fixed-selection.md).
Active caps for the bounded static Apple DASH subset are described below.

## Apple DASH Load video caps

This section records the retained AVPlayer/HLS adapter. The exact programme
route above applies caps to each prepared candidate and reports its actual
selected rendition; its lifecycle behavior is described in the P01 report.

For static clear AVC/AAC DASH on Apple, `YlLoadOptions.videoConstraints` can
set `maxWidth`, `maxHeight`, and `maxBitrate` independently or together. Explicit
DASH and automatic `.mpd` loads use the same path. A constrained load keeps only
declared video Representations within every supplied limit in every Period;
if a Period has no candidate, it fails with
`decoder.quality_constraint_unsupported` before requesting candidate media.
The bitrate field compares the MPD's declared **video Representation**
bandwidth. It does not include audio and is not a network speed limit. The
displayed frame is also checked against width and height limits before output;
an oversized or unprovable decoded frame fails that session without a first
frame.

The constrained path accepts a conservative, compatible subset of the existing
static DASH adapter: one AVC codec/profile family, compatible display ratio and
frame rate, square pixels, and no color, dynamic-range, or supplemental
declarations. The full original presentation is validated before filtering.
AVPlayer starts in automatic video selection unless an explicit fixed command
is accepted. Passing the same constraints through
`session.setVideoConstraints` succeeds. An active accepted static DASH
session can also tighten, loosen, or clear them with the same Future API while
keeping its session identity, measured position, current play/pause intent,
and accepted selection mode. The Future completes when the new item and
policy are committed; a new decoded frame can arrive later, and brief
rebuffering is possible. Changes recompile the accepted original MPD snapshot,
so they do not fetch the MPD again. A cap that leaves any Period without a
video candidate, or excludes a fixed identity in a Period containing it,
fails with `decoder.quality_constraint_unsupported` and keeps the old item and
policy. An equal accepted cap is an idempotent no-op. For an
inactive or restoring DASH session, a changed cap still returns
`policy.video_constraints_reload_required`; load the source again with new
options in that state. A rejected Load leaves the accepted session playing.
Normal HLS/MP4 video preference behavior is unchanged.
See the [Load caps report](superpowers/reports/2026-09-25-apple-dash-load-caps.md)
for the original Load behavior, and the [runtime caps report](superpowers/reports/2026-09-26-apple-dash-runtime-caps.md)
for active changes and their test scope.

## Apple DASH current-Period video catalog

This section describes the retained AVPlayer/HLS adapter catalog. The owned
programme backend reports the selected video rendition directly.

For an accepted Apple DASH Load, `state.videoTracks` lists the declared video
Representations available in the **current playback Period**, after the
accepted Load or runtime video cap has filtered them. Each entry reports the
MPD's declared width, height, video bandwidth, and codec. It is a catalog of
available qualities, not evidence of which rendition AVPlayer is decoding.
All DASH video entries have `isSelected == false`; this catalog does not report
which rendition the decoder displayed. `state.videoSelection` starts automatic
with the initial reason, then reflects an accepted user fixed/auto command or
sticky `trackUnavailable` fallback. The decoded `videoGeometry` is the
separate observation of the displayed frame.

IDs use `dash-video-w{width}-h{height}-b{bandwidth}`. They remain stable when
Representation IDs or XML ordering change between Periods, and the catalog is
sorted by width, height, then video bandwidth. At a Period boundary it follows
the measured program position; seeking back or forward restores the catalog
for the landed Period. A failed candidate Load or runtime cap change preserves
the accepted session's catalog, and Stop clears it. A successful runtime cap
change publishes the current Period's newly filtered catalog. Fixed selection
uses the same full allowed catalog and a separate effective media projection;
the catalog alone does not establish an adaptive fallback policy or a
quantitative ABR guarantee. The existing clear static AVC/AAC Apple DASH subset and its
admission limits still apply. See the [catalog stage report](superpowers/reports/2026-09-25-apple-dash-track-catalog.md)
for separate native and public evidence and the tested device scope.

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

A valid header-free resolved RTMP or RTMPS app/playpath URI converts to a
player source and retains live intent. Both reject HTTP headers and use core
URI validation. RTMPS playback is supported on Apple, including opt-in AirPlay;
Android still rejects RTMPS during native assessment. HTTP(S) conversion retains
credentials and live intent. Playback remains subject to the selected engine's route and
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

DRM protected-view feasibility has a separate Debug-only example prototype
(AVPlayerLayer on Apple; secure-requested SurfaceView with explicit hybrid
composition on Android). Clear-fixture view tests do not enable DRM in the public
player or prove secure decoding/output. See the [P06 report](superpowers/reports/2026-09-26-remaining-06-drm.md)
and [planned protected-view contract](superpowers/specs/2026-09-26-drm-contract.md);
authorized playback and actual protection remain unverified.

P06 Task 2 adds public Widevine/FairPlay configuration and a separate bounded raw
binary license POST client, with opt-in idempotent retries, same-origin-only
redirect policy, cancellation and sanitized errors. This is transport support,
not protected playback: current adapters reject DRM sources before cancelling an
existing clear load or serializing the source. Production protected-view/key
bridges and native license installation remain P06 Task 3 work; authorized
decryption and output protection remain unverified. See the
[DRM contract](superpowers/specs/2026-09-26-drm-contract.md#6-已实现的-dart-配置与许可证-post).

P06 Task 3A adds an internal Android MediaDrm key-session boundary with tested
cancellation, epoch isolation, renewal and background recreation. It is not
connected to Media3, the protected surface or the Dart license transport yet.
The internal driver requires API28+ per-session HW_SECURE_ALL evidence and
rejects API24–27 protection admission; the app-wide API24 floor is unchanged.
No production DRM capability is enabled by these internal/mock tests.

P06 Task 3B1 补齐内部 Media3 DrmSession 适配、引用释放与禁止非安全 decoder 查询；尚未连接生产 Media3 core/source factory、保护 view 或许可证 Pigeon，不构成 DRM 播放支持。视频硬件 metadata 证据仍要求 API29+；系统 L1 API28+ 与整包 API24 下限分别保留。

P06 Task 3B2 已连接 Android 内部安全候选输出、Media3 DRM manager、原生安全 SurfaceView 与会话替换/回滚。四元组/输出 revision/attach ACK 隔离旧帧；不允许明文 fallback。尚无 Dart/Pigeon 完整入口与真机授权证据，生产 DRM 支持仍未开放。

P06 Task 3B3 已实现 Android schema5 公共 Widevine 配置、Pigeon 密钥交换/取消、Task2 许可证 POST 与受保护视图描述符/ACK。API29+ 且系统识别 Widevine 才进入逐源检查；实际播放仍须安全 output、L1、实际硬件 secure decoder 与 keys usable，评估中的 unknown 不当作通过。保护路线使用显式 hybrid composition，仅支持 contain/center，拒绝非保护 fallback；明文路径保持原样。Apple DRM 留待3C。当前只有 JVM、Dart/真实 loopback POST 和 widget 组合证据，**没有授权内容解密或真机显示保护验收，CAP-DRM 未完成**。前述3A/3B1/3B2段落为各阶段交付时状态。

P06 Task3C1 增加内部 Apple AVContentKeySession streaming driver 与 SPC/CKC 生命周期。仅系统确认响应后标记 keys usable；更新撤回、迟到响应隔离、fresh asset 恢复和有界期限已纳入原生测试。该结果不证明安全decoder/HDCP/受保护显示，生产 AVPlayerLayer/候选/Pigeon 接入仍待3C2，Apple adapter 继续明确拒绝 DRM，CAP-DRM 未完成。


P06 Task3C2 已接入 Apple schema5 公共 FairPlay HLS、独立 AVPlayerLayer、候选会话/音频事务、受保护 view ACK 和 Task2 许可证传输。系统API可用性不等于授权播放可用；逐源仍需protected asset、item/key状态检查。首版仅接受无媒体自定义header的platformDefault、automatic缓冲、非强制硬解和无画质约束；音轨/variant目录暂不公开，受保护视图仅contain/center。普通播放回归及fake/loopback组合验证详见P06报告。**授权物理播放、HDCP/外接/HDR和CAP-DRM仍未完成**。前述3C1段落保留历史阶段状态。

2026-09-28 P06 Task4A 提供[私有资源预检与基础生命周期入口](../tool/drm_acceptance/README.md)。三平台授权资源仍external_missing；配置检查通过不等于实际授权/播放/输出验收，CAP-DRM状态不变。

2026-09-28 [P07-Task1调查](superpowers/reports/2026-09-26-remaining-07-dolby.md)冻结FEL/HDR源码基线和候选版本，本机6个检查程序通过；没有扩大生产杜比支持。24个调查组合均缺独立参考/容差，候选三端构建未完成，CAP-DV-MAP与CAP-DV-OUT继续未验证。

2026-09-28 P07-Task1B1仅推进研究候选：libdovi/libplacebo三端arm64构建与公开P5输入hash/首RPU验证。macOS GPU测试跳过，移动端未运行；没有新增生产依赖或提升CAP-DV-MAP/OUT。

2026-09-29研究补充：固定libplacebo在当前Apple M1/macOS27的加速CGL路径上完成有限GPU断言，详见 [P07报告](superpowers/reports/2026-09-26-remaining-07-dolby.md)。此候选仍未接入播放器，compute/SSBO能力受限；不能据此新增FEL、完整杜比映射、移动端或原生DV输出支持声明。

2026-09-29 P03新增原创格式组合与当前macOS自动路由调查，见[P03报告](superpowers/reports/2026-09-26-remaining-03-formats-decoding.md)。17条公共生命周期成功不代表输出图像/声音完整验收；有效素材失败、错误扩展名差异及未运行平台逐项保留。本次未修改生产格式支持范围。

2026-09-29 P03 MP4格式传递修复：Apple M1/macOS27下，同字节AVC/AAC MP4的本地`.bin`、无扩展名和HTTP`.bin`完成公共播放/seek/结束/释放，截断输入仍拒绝。实现使用macOS14/iOS17起的公开MIME接口；旧系统保留原行为，iOS及真实影音输出未验收。并非任意错误的已知扩展名均已修复，CAP-FORMAT整体仍未完成。

2026-09-29 P03 HEVC跳转修复：Apple M1/macOS27下既有MOV HEVC Main与MKV Main10样本的本地/HTTP/改名路径通过前向、反向seek及自然结束；普通解码路径按CRA/BLA随机访问语义过滤RASL。仅公共生命周期验证，像素/声音/同步、其他Apple设备/最低系统及FEL物理输出不由此推定。

2026-09-29 P03 FLV点播：Apple M1/macOS27实测AVC/MP3 FLV本地、HTTP显式onDemand及本地改名路径可前后seek并结束；HTTP无Range时明确拒绝seek，automatic/live仍保留直播语义，旧直播重连回归通过。未新增FFmpeg模块；其他codec、iOS/Intel/最低系统及真实声音/像素/同步仍未验收。

### Scoped Apple CELT Opus playback evidence (2026-09-29)

Historical snapshot: SILK/hybrid decoding and strict-policy exclusions below are superseded by the 2026-10-16 engineering update.

Ordinary Matroska VOD now routes Opus CELT, OpusHead v1/family 0,
mono/stereo at 48 kHz through the native decoder. Container pre-skip and tail
padding are applied once; seeks decode at least 80 ms of available preroll and
trim PCM at the presentation target. Owned AVC/Opus file, HTTP and renamed-file
lifecycle evidence is on macOS Apple M1; this does not establish physical output
quality, AV sync, iOS runtime or full WebM support.

SILK/hybrid, managed networking, bounded buffering and hardwareRequired policy
remain rejected for Opus-only sources. Mixed sources retain existing compatible
AAC/etc. choices under strict policies. Active switches into or out of Opus rewind the demux cursor, recreate the video
decoder and trim decoded audio at the frozen presentation position. Candidate
configuration failure preserves current playback. Same selected-track requests
remain no-ops. Inactive/quiesced Opus changes remain explicitly rejected until
reactivation. If a switch is cancelled after its demux cursor/buffers change,
the current operation fails safely rather than resuming incompatible decoder
history; later session generations remain protected. See the
[P03 execution report](superpowers/reports/2026-09-26-remaining-03-formats-decoding.md).

### Scoped Apple Vorbis Matroska route (2026-09-30)

Historical snapshot: the zero-delay and strict-policy exclusions below are superseded by the P03 completion and 2026-10-16 engineering updates.

Ordinary Matroska VOD accepts bounded Vorbis headers and packets for mono/stereo
44.1/48 kHz with zero CodecDelay and no leading trim. Tail trimming is supported.
The native FFmpeg decoder supplies PCM; seeks and active track changes use
200 ms preroll and target trimming. Strict network/buffer/hardware policies
exclude this route. Inactive changes fail explicitly; candidate configuration
failure preserves current playback. This scope does not establish full WebM,
multichannel, physical output, minimum-system or cross-platform acceptance.
See the [P03 execution report](superpowers/reports/2026-09-26-remaining-03-formats-decoding.md).


### Scoped Apple VP9 hardware route (2026-09-30)

Historical snapshot: the managed/bounded exclusions and absence of a software candidate below are superseded by later P03 work. Production software admission still requires qualified evidence.

Seekable ordinary Matroska/WebM VOD accepts VP9 Profile 0, 8-bit 4:2:0
SDR with fixed dimensions up to 4096×2160 and visible single-frame packets.
Opening and per-packet checks reject hidden/show-existing frames, superframes,
geometry/render-size changes, color/range changes and unsupported HDR metadata.
All decoder policies require actual hardware evidence on each session creation;
there is no VP9 software fallback or new FFmpeg decoder/parser. Supplemental
decoder registration is availability-guarded (macOS 11/iOS 26.2); older systems
still require independently available hardware, without raising deployment targets.
Managed network and bounded-buffer policies fail explicitly. Existing Opus and
Vorbis restrictions still apply, including Vorbis zero CodecDelay. AV1 remains
unsupported by this route. See the [P03 report](superpowers/reports/2026-09-26-remaining-03-formats-decoding.md)
for measured platform coverage; this does not establish physical output, sync,
minimum-system or cross-platform acceptance.


2026-09-30 AV1 evidence remains a gap: the owned Main 8/10-bit VideoToolbox
probe cannot create a decoder on this M1/macOS27 for any of the three policies,
while its AVC control fully decodes in hardware. This is device-specific and
does not imply that AV1-capable Apple devices lack a decoder. The product route
is unchanged; no Apple AV1 software budget is measured or admitted. See the
[P03 report](superpowers/reports/2026-09-26-remaining-03-formats-decoding.md).

## Subtitles (Dart opt-in)

`YlPlayerController.create(enableTextSubtitles: true)` enables a bounded external
SRT/WebVTT/TTML/ASS/SSA text and PGS/VobSub bitmap runtime with a `YlPlayerView` overlay on ordinary video and explicitly negotiated protected native surfaces. This is Dart-owned;
current native adapters still do not advertise a native subtitle SPI.

| Scope | Implementation / evidence |
|---|---|
| External file and HTTP(S) text | Streamed, bounded, cancellable; owned files and loopback GET tests |
| Text, b/i/u, entities, horizontal WebVTT position/align | Parsed and painted; Flutter widget and Ahem pixel tests, including crop/PAR/rotation/RTL |
| Selection/off/offset, replacement and seek | Public session API; atomic catalog and media-position-driven overlay tests |
| Strict managed HTTP policy | Per-hop header/read deadlines, bounded retries/Retry-After and shared redirect budget; loopback/TLS cancellation tests |
| TTML1 text subset | Namespace-aware media timing, referenced basic styles and percentage regions; file/managed HTTP, lifecycle, region rectangles and clipped color-pixel tests |
| ASS/SSA text subset | Explicit script resolution; WrapStyle/q 0–3 (default 0), bounded approximate smart wrapping with active-cue/font-change invalidation; styles/outline/shadow/position/layers/move/fad; real file/managed HTTP and Ahem fixed-time pixel tests; no libass/font-metric equivalence |
| PGS external SUP subset | Binary framing/RLE, palettes/clear, cropped/windowed objects; file/managed HTTP, manual pixel grids, late-image disposal and bounded asynchronous decode tests |
| VobSub external DVD subset | Explicit idx/sub pair, language/substream matching, PS/SPU fragments, two-field RLE, timed palette/alpha/clear; real paired I/O and owned full-pixel grids |
| Local Matroska embedded UTF8/ASS/SSA/WebVTT | Explicit committed-source discovery, TrackUID selection and shared overlay; owned EBML plus independent muxer/ffprobe and Flutter lifecycle tests |
| HTTP(S) Matroska embedded UTF8/ASS/SSA/WebVTT | Single-range206 with pinned strong ETag/length, shared managed deadlines/retry/redirect/credential policy; bounded cache/scan and real HTTP/TLS/session/widget tests |
| Local / HTTP(S) MP4 embedded tx3g (mov_text) | Non-fragmented sample tables and single-resource fMP4 fragments, Track ID selection, simple edits and basic styled literal text; same managed Range policy, independent owned FFmpeg fixtures, real HTTP and Flutter lifecycle tests; no native/device acceptance |
| Local / HTTP(S) MP4 embedded WebVTT (wvtt) | Non-fragmented vttc/vtte sample discovery, Track ID selection, basic markup and horizontal align/position; same managed Range policy, real file/HTTP and Flutter geometry/lifecycle tests; advanced WebVTT and native/device acceptance remain open |
| Local / HTTP(S) MP4 embedded TTML (stpp) | Non-fragmented discovery/selection, sample-clipped TTML composition times and simple edits, existing styled text/percentage regions; managed Range policy and raw XML catalog budget; actual file/HTTP/Flutter validation, no device or full TTML/IMSC claim |
| Local / HTTP(S) fMP4 embedded WebVTT / TTML | Same-resource initialization + moof/mdat discovery; trex/tfhd/trun defaults, tfdt/composition times, sample clipping/edits; managed Range, real file/HTTP and Flutter selection/region/lifecycle tests; no separate segment URLs, manifests/live polling or device acceptance |
| Hybrid MP4 embedded tx3g / WebVTT / TTML | Initial sample tables plus later fragments in one resource; per-track decode continuity, shared byte extents/budgets and atomic managed loading; owned three-codec fixtures, independent FFmpeg tx3g, real HTTP/Flutter validation; no native/device claim |
| Local / managed HTTP(S) Matroska embedded PGS | TrackUID discovery/selection, raw binary segments, container timing/duration, existing palette/RLE overlay and shared encoded/RGBA budgets; owned plus independent FFmpeg fixture, HTTP and pixel/lifecycle tests; no native/device claim |
| Local / managed HTTP(S) Matroska embedded VobSub | TrackUID discovery/selection, IDX global CodecPrivate, raw SPU with container timing/caps, shared DVD RLE/alpha overlay and encoded/RGBA budgets; independent FFmpeg fixture, actual HTTP and Flutter pixel/lifecycle tests; no native/device claim |
| Matroska subtitle block compression | Single block-only zlib/header stripping before supported text/PGS/VobSub decode; strict framing, bounded restoration and persisted stored-byte budgets; Python zlib golden streams, file/managed HTTP and widget tests; no native/device claim |
| Matroska subtitle CodecPrivate compression | Single zlib/header stripping for Private or Block+Private scope, before UTF8 and existing ASS/SSA/WebVTT/VobSub header parsing; stored/restored header limits and retained empty-track/catalog budgets; owned Python compression goldens, file/managed HTTP and widget tests |
| Other embedded containers/codecs, advanced TTML/ASS/SSA/PGS/VobSub and advanced WebVTT | Not implemented by this runtime |
| Asynchronous bitmap resource failure | Sanitized `subtitle.resource_unavailable`, failed active cue suppressed, video continues; stale callbacks and partial images released |
| Negotiated protected external subtitles | `supportsSubtitleOverlay` defaults false; bundled native adapters allow a separate clear subtitle sibling with matching identity/platform, session first frame and geometry. Protected embedded discovery rejects before I/O. Clear native probes only; actual DRM composition not accepted |
| HDR brightness and physical-device subtitle sync | Await physical HDR output / licensed DRM / suitable measurement devices; controlled clock observations do not establish luminance or physical A/V sync |

The ordinary Flutter path is available to Android/iOS/macOS consumers. The P02
continuation adds real-player seven-format composition and lifecycle tests on
Android emulator, iOS Simulator and macOS; per-platform actual results and
limitations are in the report. Embedded/container combinations retain their
individual evidence rows above. Synchronization follows the configured position
update cadence; this is not physical screen/speaker synchronization acceptance. See the
[P02 report](superpowers/reports/2026-09-26-remaining-02-tracks-subtitles.md) and
[runtime contract](superpowers/specs/2026-10-11-subtitle-runtime.md).

### Matroska WebVTT overlay extension (2026-10-12)

S_TEXT/WEBVTT and Matroska D_WEBVTT/SUBTITLES/CAPTIONS now feed the shared Dart
WebVTT renderer with TrackUID selection. Existing managed Range transport is
unchanged. Owned standard-mapping fixtures, a host-FFmpeg legacy-mapping MKV,
HTTP and fake-backend widget tests are the evidence boundary. No native/device,
WebM DocType, advanced WebVTT or whole-P02 completion claim.

### WebM subtitle overlay continuation (2026-10-12)

The previous subtitle WebM DocType exclusion is now superseded: file/managed HTTP(S)
WebM D_WEBVTT/SUBTITLES and CAPTIONS use TrackUID selection and the existing overlay.
Automatic content detection and explicit webm are covered; explicit format mismatch
rejects. Owned VP9/WebVTT FFmpeg fixture, HTTP and fake-backend rendering tests are
the evidence boundary. Native video routes, advanced WebVTT, physical-device and
whole-P02 acceptance are unchanged.

### MP4 subtitle structural budget (2026-10-13)

The container index, tx3g configuration/sample-modifier boxes, WebVTT
configuration/sample/cue boxes and TTML configuration boxes share a 200,000-box
allowance across tracks, sample descriptions and initial/fragmented samples.
Font entries and style records retain their separate existing bounds.
Exact-boundary parser tests and file/managed HTTP failure-preservation tests
cover this Dart path. No new native or physical-device acceptance is claimed.

### Matroska subtitle compression chains (2026-10-13)

Up to four zlib/header-stripping stages restore blocks and/or CodecPrivate in
reverse encoding order, with unique orders and independent scope filtering.
Stored, intermediate and final bytes share parser/catalog budgets. Codec matrix,
Python compression goldens, actual file/managed HTTP and widget tests cover the
Dart path. Next scopes, encryption and WebM compression remain unsupported;
no independent muxer, native or physical-device acceptance is claimed.

### MP4 extended subtitle language (2026-10-13)

The Dart subtitle path supports a single `mdia/elng` on tx3g/wvtt/stpp tracks in
ordinary, fragmented and hybrid MP4. Well-formed BCP 47 tags (up to 128 ASCII
characters) override packed `mdhd` metadata and retain spelling; track IDs remain
stable. Invalid metadata rejects atomically, with existing file/managed HTTP loading
and selection preserved. Validation covers owned fixtures and fake-backend widgets,
not independent muxer interoperability or native/device display acceptance.
[Contract](superpowers/specs/2026-10-13-subtitle-extended-language.md).

### Apple DASH audio selection

Each supported audio AdaptationSet becomes an independent HLS AUDIO rendition.
Audio IDs use declared content ID, language, roles and encoding configuration;
Period/Representation order, representation IDs, bitrate and URL do not define
identity. Same-language commentary stays independently selectable. Every Period
must retain the same complete identity set; duplicates, additions, removals and
encoding changes reject before publication. Missing language is not guessed.
The private loader retains its existing credential and resource limits; explicit
strict managed admission remains unsupported. This adds no audio ABR or mixing.

Selection survives same-session DASH quality replacement. Generic AVPlayer
options use system property-list restoration, not array positions or labels. A
selected identity that cannot be restored reports `track.not_found`. New loads
reset selection. See the [P02 report](superpowers/reports/2026-09-26-remaining-02-tracks-subtitles.md)
for tested platforms and the separate physical-audio acceptance boundary.

### Android audio content identity

Media3 publishes one audio choice per content group, with opaque IDs independent
of group order and rendition bitrate. For DASH, identity includes the declared
AdaptationSet ID plus normalized language, roles and encoding-family metadata;
Representation IDs and generated `unset:<index>` group IDs do not define content.
Other formats use the available Format IDs plus semantic metadata; changing these
IDs does not promise continuity. Missing IDs never become public array indices;
indistinguishable groups reject `policy.unsupported`. Identity work is bounded to
128 audio groups, 4096 formats and 1024 characters per identity string.

Explicit audio selection captures intent independently of observed selection. It
is restored before preparation and enforced by the playback-thread selector for
reading-ahead Periods. A missing chosen group reports `track.not_found`, including
during prebuffering before a boundary; it does not use video PD-01 fallback. Empty
transient public callbacks retain intent, while Stop/new preparation resets it.
Manual selection picks one supported rendition inside the chosen group; automatic
Media3 adaptation and managed networking retain their existing policies. See the
[P02 report](superpowers/reports/2026-09-26-remaining-02-tracks-subtitles.md) for
exact tests and separate device/physical-audio limitations.

## P03 controlled output evidence (2026-10-15)

Production software admission remains empty on both adapters. The Apple AV1/VP9
and Android AVC/HEVC software implementations have controlled ownership/lifecycle
checks; their synthetic test limits are not production device profiles.

The Android matrix currently records 59 required paths with displayed markers,
seek, completion and disposal, plus six required AV1/Main10 paths unavailable on
the selected emulator. macOS records 62 such required paths and three unavailable
AV1 paths on the selected M1. These rollups span explicitly separate runs, retain
original failures, and exclude diagnostic/negative-control cases from support.
Native PCM is measured separately; the public rows do not prove combined A/V
output or physical synchronisation. See the [P03 report](superpowers/reports/2026-09-26-remaining-03-formats-decoding.md)
for iOS hardware gaps, exact identities and remaining acceptance conditions.

Five optimized Mac process measurements of the installed AV1 bridge passed their
fixed short protocol and actual pixel controls. Sustained thermal qualification,
independent verification and the matching product/device build are still needed
before production admission. This work does not change long-play or weak-network
ABR tooling.

2026-10-15 P03 PCM follow-up: owned Apple Dolby packets use the existing minimal
FFmpeg bridge to preserve priming/final frames and native speaker layout.
Dolby/DTS/FLAC seek and track switches decode preroll, then clip actual PCM at
the programme target. Android Dolby no longer applies codec initial padding a
second time. Pinned boundary/switch controls compare sample counts, packet PTS
and unshifted first/last windows; host Lo/Ro references explicitly match the
integer stereo policy. This is separate-build regression evidence (shared
FFmpeg ancestry except CoreAudio FLAC), not physical audio or full CAP acceptance.
See the [PCM follow-up evidence](superpowers/reports/evidence/2026-10-15-p03-pcm-alignment/README.md).

The final PCM bridge was remeasured with five fresh optimized processes and six
AVC controls; the short protocol is valid for its exact new binary identity.
Production eligibility remains false because sustained thermal and independent
product verification evidence are absent. Focused native results are macOS74,
iOS7 (pure audio), Android22, all passing with no skips; this does not replace
the previously recorded required hardware/combined-output gaps.


2026-10-16 AVPlayer public Flutter observation: opted-in Debug builds now retain
real pre-effects PCM, attached-layer pixels, separate seek epochs and actual tap
finalization from the same local MP4 player on macOS and iOS Simulator. Both
platforms pass the separate source-pull gate; macOS's existing six consumption
controls also pass. A queue-fill range is not a hardware played-sample counter:
AVPlayer strict consumption acceptance remains false. Ordinary Debug and Release
exclude the observer. Remote/DRM/multiple-track capture and full P03 remain open.
See the [AVPlayer evidence](superpowers/reports/evidence/2026-10-16-p03-avplayer-audio/README.md).


## P03 strict progressive engineering (2026-10-16)

Apple MP4/MOV, MPEG-TS, MPEG-PS and AVI VOD now select owned samples when managed networking, bounded buffering or hardwareRequired is requested. The existing managed byte-source credentials/deadlines/cancellation and shared allocation ledger apply. Hardware-required video still needs actual decoder evidence during preparation and recreation; audio conversion does not claim to be hardware accelerated. HLS strict-policy exclusions and progressive live exclusions are unchanged. Ordinary MP4/MOV retain AVPlayer by default. Inspected wrong-name MOV also uses owned samples below the public MIME-override OS versions.

Seekable Matroska Opus (CELT/SILK/hybrid) and Vorbis can use strict policies, and the admitted VP9 hardware profile can use bounded buffering. Missing Opus/Vorbis packet durations reserve the converter's maximum output duration only in the queue ledger; compressed packet timing is preserved and actual decoded PCM determines output timing. Unsupported codecs, rates, profiles and live inputs remain explicit failures.

The engineering paths do not qualify unmeasured software profiles, hardware-unavailable simulators, minimum OS/Intel systems, or physical output. AVPlayer source-pull evidence still does not establish a hardware played-sample clock. See the [P03 report](superpowers/reports/2026-09-26-remaining-03-formats-decoding.md) for recorded runtime coverage and remaining acceptance conditions.


## P05 controlled business evidence (2026-10-20)

TVS now admits RTMPS syntax and keeps native RTMP/RTMPS recovery independent of
business proxy initialization and additional same-source retries. Awaitable
provider disposal joins initiated asynchronous cleanup and reports errors.
Owned macOS TVS acceptance covers two-channel M3U/JS playback, live mode changes,
three native reconnects, terminal exhaustion, explicit recovery, failed refresh
preservation, cancellation and stop. The nine frozen scripts separately execute
and hand off to owned media on Android, iOS Simulator and macOS.

These are controlled session/first-frame/transport observations. They do not
establish original online-source availability, physical audio/video, complete
heap leak freedom, all device/OS coverage or sustained P08 SLOs. See the
[P05 evidence report](superpowers/reports/2026-09-26-remaining-05-live-business.md).
