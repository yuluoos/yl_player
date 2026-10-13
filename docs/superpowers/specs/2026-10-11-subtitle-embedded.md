# Local Matroska embedded text subtitle slice

Execution continues P02 Task 2/3 and the existing optional Dart subtitle owner.
The requested discovery → selection → rendering chain is implemented for local,
stable Matroska files containing S_TEXT/UTF8, S_TEXT/ASS and S_TEXT/SSA. This is
an explicit first embedded-container slice, not all-container/native acceptance.

## Public behavior

With `YlPlayerController.create(enableTextSubtitles: true)`, load a local MKV,
then call `session.discoverEmbeddedSubtitles()`. Read
`player.state.subtitles.tracks`, select its `id` using
`session.selectSubtitleTrack(id)`, and display the existing `YlPlayerView`.
`YlPlayerOperation.embeddedSubtitles` advertises this scoped operation. Default
controllers reject it; native adapters do not advertise it or receive a new wire
ordinal. Discovery reads the committed source only and is an explicit command,
so subtitle failure does not choose whether video should survive (PD-03 remains
open). A new session starts off with zero offset; rediscovery preserves a still
present selected identity. Errors are sanitized command failures.

Track identity is `mkv:<unsigned TrackUID>`, scoped to the playback session,
independent of order, TrackNumber, language or label. Duplicate UID/number is
malformed. LanguageIETF takes precedence over Language; absent language defaults
to `eng` per Matroska. FlagForced is represented as `forced` role. Enabled text
tracks with unsupported codecs cause atomic rejection, not silent omission or
mislabeling. Disabled tracks and non-subtitle tracks are not published.

Discovery replaces only embedded entries. External replacement/clear retains
embedded entries and selection; discovery retains external entries. Cross-owner
ID collisions reject atomically. Missing selected UID clears selection without
same-language remapping. External and embedded data share 4 MiB input, 10,000
cues, 20,000 runs and 64 MiB bitmap catalog budgets. Existing media-clock query,
positive/negative offset, first-frame gate, seek clear/requery, stop, disposal and
source replacement rules apply. Later catalog commands cancel earlier work.
File scans serialize per runtime and close handles before the next scan.

## Container and document rules

Random-access reads skip media payloads. Read limits: 128 total tracks, 32 enabled
subtitle tracks, 50,000 clusters, 2,000,000 inspected elements, 64 MiB total
requested bytes, 256 KiB CodecPrivate per track, 64 KiB subtitle packet and a
30-second cooperative I/O deadline. One input subtitle catalog is bounded before
rendering. Parsing always validates parent boundaries; unknown-size Segment is
allowed, unknown-size children are rejected. Ordinary video BlockGroups may
carry repeated ReferenceBlock elements. Explicit ReferencePriority=0 is neutral;
nonzero priorities are unsupported. Disabled entries do not consume the enabled
subtitle-track allowance, but still count toward the 128 total-track bound.

Cluster timestamp plus signed Block timestamp uses TimestampScale, minus
CodecDelay. BlockDuration uses TimestampScale; DefaultDuration is nanoseconds.
SimpleBlock needs DefaultDuration. Preserve microseconds; reject negative or
out-of-seven-day-range presentation times, zero duration and sub-microsecond-only
intervals. Nonneutral TrackTimestampScale/TrackOffset, content compression or
encryption, invisible/laced subtitle blocks, BlockAdditions, CodecState,
DiscardPadding and segment linking reject. No fonts or attachments are loaded.

UTF8 packets become cues directly, avoiding synthetic SRT text that could turn
payload into timing/extra cues. ASS/SSA parses CodecPrivate styles once, consumes
Matroska packet field order and ReadOrder, rejects duplicate ReadOrder, preserves
commas in text and feeds exact container times to the existing style renderer.
Private headers cannot inject Dialogue events. Existing ASS/SSA effect and font
subset restrictions remain in force.

## Verification and remaining scope

Owned EBML fixtures cover corruption, cancellation, identities, timing and
budgets. A separate tiny MKV produced by the host FFmpeg CLI contains real MPEG-4
video plus two SRT tracks; ffprobe evidence records stream flags and packet times.
This tool is fixture-only: no production binary, recipe, dependency or bridge is
changed. Flutter widget tests exercise the real extraction and overlay with a
fake video backend. This is not physical-device or native decode acceptance.

Network/managed-range container extraction, MP4/HLS/DASH/WebM, Android content
URIs, embedded TTML/WebVTT/bitmap codecs, streaming unknown-size clusters,
compressed/encrypted subtitles and native subtitle callbacks remain unsupported.
HDR/protected subtitle output and full P02/CAP-SUB acceptance remain open. Existing
external managed network and supported text/bitmap formats remain available.
Long-play and weak-network ABR files/workloads are excluded.

## Primary format references

- https://www.matroska.org/technical/subtitles.html
- https://www.rfc-editor.org/rfc/rfc9559.html (TrackUID, blocks and timestamps)

Only format facts were consulted. No external subtitle/media content or source
code was copied. Fixture text is authored for this repository.


## Subsequent network extension

The local-only scope above records this slice's original acceptance. HTTP(S)
Matroska text discovery is subsequently implemented under [the network
contract](2026-10-11-subtitle-network-matroska.md), using managed single-range reads
with stable strong ETag/length and bounded caching. Other exclusions remain.

## Matroska PGS continuation (2026-10-12)

The previous embedded-PGS exclusion is superseded by the
[Matroska PGS contract](2026-10-12-subtitle-embedded-pgs.md). File/managed HTTP
S_HDMV/PGS uses container-timed binary packets and the existing bitmap renderer;
encoded and expanded catalog budgets are shared with external subtitles.
Other format/effect/native/device boundaries remain.


## 2026-10-12 Matroska VobSub 扩展

此前未覆盖的 Matroska `S_VOBSUB` 已接入本地文件和 managed HTTP(S) 发现、选择与位图渲染。
CodecPrivate 全局设置及原始 SPU 使用容器时间，不请求 IDX/SUB 旁路文件；复用既有 DVD
控制/RLE/透明度解码与共享位图预算。本文原先内嵌 VobSub 的排除项由
[内嵌 VobSub 契约](2026-10-12-subtitle-embedded-vobsub.md)限定替代；高级效果、设备、
清单/直播和其他容器仍不在此范围。
