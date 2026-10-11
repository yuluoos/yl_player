# ASS/SSA external text rendering slice

P02 Task 3A, opt-in `enableTextSubtitles: true`. Existing managed resource loading,
transactional catalog and public media-clock lifecycle are reused. No native
builds or long-play/weak-network ABR changes in this slice.

## Supported contract

Strict UTF-8 ASS v4.00+ / SSA v4.00; explicit PlayResX/Y and WrapStyle 1 (greedy)
or 2 (explicit newlines only). Style and event Format columns may be reordered;
Text must be last. ASS Layer; SSA Marked=0/1; centisecond times, [start,end).
Style font family with Flutter/platform fallback, size, bold/italic/underline/
strikeout, primary/outline/shadow color and alpha, outline/shadow, 9 alignments,
script-space margins. SSA alignment conversion and legacy colors handled.

Overrides: b/i/u/s, fn/fs, c/1c/3c/4c, alpha/1a/3a/4a, bord/shad,
an/a, pos, move (4 or 6 parameters), fad, q1/q2, r or rStyle.
N/n/h escapes, inline comments, literal <b> and & text. Position/move/fad are
line-wide, at most once; conflicting position/move rejected. Media position
minus subtitle offset drives effects; no animation timers. Higher Layer paints
last; default positioned same-layer cues avoid collisions in document order;
explicit pos/move overlap intentionally. Rendering is clipped to the visible
video aperture after rotation/PAR/fit. Fonts are requested from Flutter's
existing font collection; no font or image resource I/O.

## Explicit limits and exclusions

4 MiB/catalog, 10,000 cues/catalog, 64 simultaneously active/document,
16,384 code units/cue, 512 runs/cue and 20,000/catalog (remaining budget enforced before allocating ASS runs); 128 styles, 128 font names
(at most 128 units each)/document; 50,000 lines, 4,096 units metadata line.
PlayRes dimensions 1..8192, font size (0,256], outline/shadow 0..16, coordinate
absolute value <=8192, time <=7 days; bounded before renderer allocation.
Each paint creates/disposes at most four TextPainters per cue; fades use a
temporary compositing layer clipped to the visible cue rectangle. No retained
bitmap/font caches or independent timers. The shared Flutter font cache is
engine owned, not billed as a subtitle font cache.

Unsupported: smart wrapping 0/3 (including omitted WrapStyle's default 0),
vector drawings/clips, karaoke, transforms/rotation/scaling/spacing, blur,
border style 3, embedded fonts/images, embedded subtitle tracks, legacy
non-UTF-8 encodings, effect field, unscaled borders, reverse collisions,
non-None YCbCr matrix conversion, and mixed shadow offsets within one cue. Unknown rendering semantics fail atomically
with subtitle.unsupported rather than silently dropping effects. Malformed
syntax maps subtitle.malformed; budget violations subtitle.tooLarge. Errors
contain no source text. Existing selected catalog survives failed replacement.

Flutter text shaping/font metrics are not libass/VSFilter pixel equivalence.
This slice does not certify native-device/HDR/protected output or full ASS/SSA
conformance, and does not complete P02/CAP-SUB. Full smart wrapping/libass and
three-platform real-font visual acceptance remain tracked follow-up work.

## Candidate and reference audit

Repository FFmpeg 9.0.1 locks pin upstream SHA256
cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635.
Both platform build recipes disable autodetection and avfilter, and enable
only listed audio/video decoders; no libass module is enabled. Actual platform
binary hashes/build-recipe hashes are retained in evidence/artifact-audit.json.
libass is an ISC licensed candidate with FreeType/HarfBuzz/FriBidi and font
provider integration; no libass binary is added to the shipped artifacts here.
This implementation adds no package/native dependency or downloadable fonts.

Primary references consulted 2026-10-11:
- [Aegisub override tags](https://aegisub.org/docs/latest/ass_tags/)
- [Aegisub script properties](https://aegisub.org/docs/latest/properties/)
- [libass project and license](https://github.com/libass/libass)
- [libass SSA version history](https://github.com/libass/libass/wiki/SSA-Version-History)
- [libass 0.17.4 parser reference](https://github.com/libass/libass/blob/0.17.4/libass/ass.c)

Tests use owned scripts and manually derived script-coordinate reference boxes
with Ahem glyphs. These measure positioning, clipping, layering, outlines and
media-time effects, not platform font appearance. Real file/loopback managed
HTTP I/O is tested; public lifecycle uses the existing fake platform.
