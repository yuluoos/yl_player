# External PGS / SUP bitmap subtitle slice

P02 Task 3B. `enableTextSubtitles: true` retains its existing public name and
single external-subtitle owner, now accepting `YlSubtitleFormat.pgs` for local
SUP or managed HTTP(S). Binary payload never enters UTF-8/text markup parsing.
No native FFmpeg rebuild, generated bridge changes, new package or dependency.

## Parser and presentation

SUP `PG` magic, big-endian 32-bit PTS/DTS and length-prefixed segments. PCS PTS
is 90 kHz presentation time; DTS and other segment PTS are not cue time. PCS
wraps unwrap forward across 32 bits; backward non-wrap times reject. Seven-day
existing timeline ceiling applies. Display sets start with PCS and end with END;
incomplete, duplicate or unknown segment structures reject atomically.

PDS (up to 8 epoch palettes), ODS (up to 64 cached objects, first/continuation/
last segments with version/declared-length validation), PCS (0..2 objects),
WDS (0..2 windows) and empty END. Strict RLE decoding checks each row length,
EOL, full height and absence of trailing bytes before exposing pixels. Palette
updates preserve omitted entries; undefined entries are transparent. Limited
range YCbCr uses BT.601 for height <=576, BT.709 above, as the common SUP
convention (SUP carries no color-matrix tag). Output RGBA is premultiplied.

Normal/epoch/acquisition display sets support explicit WDS plane redraw or an
empty PCS clear. Palette-only update sets recolor the previous plane, ignoring
placeholder PCS references; ODS/WDS mutation in a palette-only set rejects.
Cache-only nonempty redraw without WDS and reserved composition flags/states
are explicitly unsupported. This is a defined external SUP subset, not Blu-ray
interactive-graphics or complete disc decoder certification.

Composition cropping selects object source pixels and places the cropped
rectangle at PCS x/y, followed by window/canvas clipping. Object order defines
overlap. Forced flags are preserved; selecting a track displays all of its
objects (no implicit forced-only filter). A new completed display closes the
old interval; equal-time displays replace it. Empty display clears immediately.
A final nonempty display persists to session end or the seven-day ceiling.
Queries use media position minus public offset and are seek-history independent.

## Resources and lifecycle

Shared catalog: 4 MiB encoded input, 10,000 cues, 20,000 text runs. Independent
PGS ceiling: 64 MiB expanded RGBA per catalog, with remaining allowance passed
to each parser and checked before allocation; old committed catalog and pending
replacement have separate bounded ownership. At most 50,000 SUP segments and
10,000 display sets per document. Dimensions 1..8192; each object <=4,194,304
pixels; indexed epoch cache <=16 MiB, with RLE bytes bounded by encoded input.
ODS declared lengths are checked before buffering; uncompleted object fragments
cannot be published. These are subtitle budgets, not a media-buffer claim.

Only the currently visible PGS frame creates engine images (at most two,
<=32 MiB raw pixels); the widget releases its owned handles on frame/track
change and unmount, including seek/off/source reset gates. Stable media time
and geometry-only rebuilds reuse the same handles. Portable asynchronous ImmutableBuffer/ImageDescriptor/Codec decoding works on
Skia. A global two-job queue coalesces replaced requests; late results are
disposed, never published. Each job decodes at most two images sequentially.
Engine decoding/raster work and temporary copies are engine-owned; no retained
whole-track GPU cache or frame timer is added. Multiple player views own
independent active image pairs; the job cap does not cap mounted views or RSS.

The existing video-aperture convention (fit/PAR/rotation/crop) applies to bitmap
placement, with upright subtitles and clipping. Cover fit uses the visible
source fraction of the bitmap canvas rather than compressing the full plane. Nearest-neighbor drawing makes
owned pixel reference cases deterministic; no OCR/text/font substitution.

Malformed data, unsupported semantics and resource limits use the existing
sanitized command failures. A failed replacement preserves the selected old
catalog and does not decide PD-03 video-survival policy. Protected surfaces
retain their command gate. HDR/DRM brightness/surface acceptance, embedded PGS,
VobSub, real-device synchronization and whole P02/CAP-SUB remain open.

## Reference and artifact evidence

The prior [artifact audit](../reports/evidence/2026-10-11-subtitle-ass/artifact-audit.json)
pins current FFmpeg 9.0.1 binary/recipe/lock hashes. Recipes do not enable
pgssub decoding or SUP demuxing. This slice uses an original Dart parser and
Flutter RGBA composition; it does not add or claim upstream codec capability
in shipped native artifacts. Primary references consulted 2026-10-11:

- [FFmpeg SUP framing reference, n8.0](https://github.com/FFmpeg/FFmpeg/blob/n8.0/libavformat/supdec.c)
- [FFmpeg PGS binary structures/RLE/color convention, n8.0](https://github.com/FFmpeg/FFmpeg/blob/n8.0/libavcodec/pgssubdec.c)
- [FFmpeg discussion of palette-only graphic-plane semantics](https://ffmpeg.org/pipermail/ffmpeg-devel/2023-May/310098.html)
- [Flutter portable raw image descriptor](https://api.flutter.dev/flutter/dart-ui/ImageDescriptor/ImageDescriptor.raw.html)
- [API in minimum Flutter 3.44.0](https://github.com/flutter/flutter/blob/3.44.0/engine/src/flutter/lib/ui/painting.dart)

Reference data/code is not vendored or linked; no additional license payload
is introduced. Owned synthetic SUP samples have manually derived time/position/
RGBA expectations. Pixel tests and handle-release tests are local Flutter
acceptance; public playback lifecycle uses fake platform events with real file
and loopback HTTP loading. No long-play or weak-network ABR workload is run.
