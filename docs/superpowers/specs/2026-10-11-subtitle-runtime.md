# External text subtitle runtime

This slice connects the existing catalog/session API and bounded SRT/WebVTT
parser to actual file/HTTP reads and Flutter rendering. Enable explicitly with
`YlPlayerController.create(enableTextSubtitles: true)`. The default retains the
optional native SPI behavior. Enabling alongside a native subtitle SPI is
rejected, avoiding two owners of the catalog. This is external text only;
embedded tracks, TTML, ASS/SSA, bitmap subtitles, HDR brightness qualification
and protected-video composition remain separate P02 work. Protected surfaces
reject subtitle commands and never receive this Flutter overlay.

The controller merges local subtitle publications with native state using a
separate native revision watermark and monotonically increasing public revision.
With this opt-in, event revisions refer to the public snapshot observable at
controller delivery; original session identity and occurredAt remain unchanged.
They are observation revisions, not the originating native revision. This keeps
late FirstFrame milestones observable without an unbounded historical mapping.
The default native-SPI path retains its existing event revisions.
Native snapshots cannot erase the local catalog. Each catalog replacement reads
and validates all documents before atomically committing. A newer replacement
cancels the prior read; failure keeps the committed catalog and selection.
Selection and offset commands during a read apply immediately to the committed
catalog; completion preserves the latest selection if its ID still exists.
New sessions reset catalog, selection and offset; stop/dispose cancel reads.

Cues use the published media position, with no wall-clock extrapolation. Thus
pause and buffering freeze subtitles and speed follows the native media clock.
Seek clears the overlay immediately and waits for a position snapshot after its
ACK. The display precision is bounded by the configured native position update
interval, not a frame-accurate synchronization claim. Before FirstFrame, after
completion/failure/stop, or without video geometry, no overlay is drawn.

The runtime supports plain text and balanced b/i/u tags, common named entities
and numeric Unicode entities. Other markup is rejected explicitly. WebVTT
position/align are supported for horizontal, bottom-stacked cues. Text is kept
upright within the visible video rectangle after fit, crop, alignment, pixel
aspect ratio and rotation. It ignores pointer input and uses a fixed white text
style with a dark background. No CSS, fonts, external references or HTML run.

Files and HTTP(S) have a 4 MiB aggregate input and 10,000 aggregate cue budget;
old and replacement catalogs may coexist during atomic replacement (up to twice
the catalog budget). At most one replacement read is active. Parsing/render span
counts are bounded separately. HTTP platformDefault uses a 30-second total
deadline, at most five redirects, no retries, system certificate validation,
identity encoding and permanently strips credentials on origin change. Managed
HTTP is implemented by the [managed network extension](2026-10-11-subtitle-managed-network.md),
with per-hop/read deadlines and explicit retry/redirect budgets. File reads
are streamed and cancellable. Errors are sanitized command failures; they do not
commit a damaged catalog or decide PD-03's eventual playback-failure policy.

Validation uses owned local files, loopback HTTP and Flutter widget rendering.
It does not claim native-device playback, HDR or DRM visual acceptance.

## TTML extension (2026-10-11)

The subsequent [TTML text subset](2026-10-11-subtitle-ttml.md) adds explicitly
selected `YlSubtitleFormat.ttml` to the same resource/catalog/clock pipeline.
The earlier SRT/WebVTT markup and layout rules remain format-specific; TTML
uses already decoded styled runs and clipped percentage regions. Advanced
TTML and full native/device format acceptance remain outside this extension.

## ASS/SSA extension (2026-10-11)

The subsequent [ASS/SSA text subset](2026-10-11-subtitle-ass.md) adds external
UTF-8 styled text, position/layers and media-time move/fad using the same managed
loader, catalog and lifecycle gates. It has explicit rendering/budget limits;
full libass equivalence, smart wrapping and native/device acceptance remain open.

## PGS extension (2026-10-11)

The subsequent [PGS binary SUP subset](2026-10-11-subtitle-pgs.md) adds external
bitmap loading through the same owner and managed loader. Binary payloads bypass
text decoding. A separate 64 MiB expanded catalog budget precedes allocation;
only active frames create images, with a two-job asynchronous decode queue and
late-result disposal. Cover fit follows source cropping. VobSub, embedded PGS,
HDR/protected output and physical-device acceptance remain open.

## VobSub extension (2026-10-11)

The [VobSub DVD subset](2026-10-11-subtitle-vobsub.md) adds explicitly paired
.sub/source and .idx/companion resources, with per-source managed policies under
one cancellation token and the shared encoded/expanded catalog budgets. The
PGS compositor also draws these immutable RGBA frames. Public metadata and native
protocols are unchanged; one entry selects one index substream. Advanced DVD/HD,
embedded, HDR/protected output and physical-device acceptance remain open.


## Embedded local Matroska extension (2026-10-11)

The same opt-in owner now supports explicit `discoverEmbeddedSubtitles()` for
its committed local Matroska source, covering UTF8/ASS/SSA with stable TrackUID
identities and existing rendering/lifecycle. Catalog operations preserve the
other origin and share aggregate budgets. See [the exact embedded contract](2026-10-11-subtitle-embedded.md).
Earlier embedded exclusions above describe prior slices; other containers,
network/bitmap embedded streams and native subtitle callbacks remain open.


## Network Matroska extension (2026-10-11)

The same discovery command now supports committed HTTP(S) Matroska UTF8/ASS/SSA
sources through the existing managed HTTP transport. Require single byte-range
206, stable strong ETag/length and If-Match; bounded windows/scan share policy
counters and credential scope. Earlier network-embedded exclusions describe the
local slice; [the network contract](2026-10-11-subtitle-network-matroska.md) defines
current boundaries. Other containers, embedded bitmap codecs, native callbacks,
HDR/protected and physical-device qualification remain open.

## MP4 tx3g extension (2026-10-11)

The earlier MP4 exclusion is superseded for non-fragmented local / HTTP(S) tx3g
tracks by the [MP4 contract](2026-10-11-subtitle-mp4.md). Discovery uses the same
catalog owner and managed range reader; styled literal text remains separate
from external SRT markup. Fragmented/other subtitle codecs and device/native
acceptance remain open. No runtime dependency, public enum or bridge changes.

## MP4 WebVTT extension (2026-10-11)

Non-fragmented MP4 wvtt now uses the same discovery/selection owner and managed
Range reader, with existing public `webvtt` format and shared horizontal settings.
Sample payloads become cues directly, preserving identifiers and sample clock
intervals without serializing a WebVTT file. See the
[bounded MP4 WebVTT contract](2026-10-11-subtitle-mp4-webvtt.md).

## MP4 TTML extension (2026-10-11)

The earlier stpp/MP4-TTML exclusion is superseded for the non-fragmented bounded
subset in the [MP4 TTML contract](2026-10-11-subtitle-mp4-ttml.md). Existing public
`ttml`, styled runs/regions and managed Range loading are reused. Composition
time, sample clipping and simple edits are explicit; advanced TTML remains rejected.

## fMP4 extension (2026-10-11)

The earlier fragmented-MP4 exclusion is superseded for the bounded wvtt/stpp
subset in the [fMP4 contract](2026-10-11-subtitle-fmp4.md): initialization and
fragments in one complete file or stable HTTP resource, shared managed Range
loading and existing render subsets. Separate segment URLs, manifests/live
polling, fragmented tx3g and native/device acceptance remain outside scope.

## Fragmented tx3g extension (2026-10-11)

The earlier fragmented-tx3g exclusion is superseded by the [fMP4 tx3g contract](2026-10-11-subtitle-fmp4-tx3g.md).
Same-resource initialization and fragments reuse existing tx3g styles/normalized
`srt` catalog entries, fragment timing and managed Range; all other stated scope
limits remain in force.

## Hybrid MP4 extension (2026-10-12)

The earlier empty-initial-subtitle-table requirement is superseded by the
[hybrid MP4 contract](2026-10-12-subtitle-hybrid-mp4.md). Initial stbl samples and
later moof samples now share track state, decode continuity, subtitle extents
and budgets in one complete resource; existing codecs, managed loading and
rendering subsets remain in force.

## Matroska WebVTT extension (2026-10-12)

The same file/managed HTTP discovery route now admits S_TEXT/WEBVTT and Matroska
D_WEBVTT/SUBTITLES or CAPTIONS. The two metadata layouts are decoded separately;
raw header/comment bytes remain charged to the shared catalog budget. Existing
WebVTT rendering and lifecycle constraints apply; no WebM DocType or native
capability expansion. See [contract](2026-10-12-subtitle-matroska-webvtt.md).

## WebM continuation (2026-10-12)

The previous WebM DocType exclusion is superseded by the [WebM contract](2026-10-12-subtitle-webm.md).
Automatic content detection and explicit webm now accept D_WEBVTT subtitle/caption
tracks; explicit Matroska/WebM hints are checked against DocType. Other constraints remain.

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


## 2026-10-12 Matroska 压缩字幕扩展

此前一概拒绝ContentEncodings的范围缩减：Matroska支持单层Order0/Scope1/Type0的zlib或
header stripping，恢复后的Block复用已有字幕codec解码。压缩输入/settings和恢复内容共同
计入预算，并跨目录更新保留。其他算法、私有头/链式编码、加密及WebM压缩仍拒绝；见
[压缩字幕契约](2026-10-12-subtitle-compression.md)。
