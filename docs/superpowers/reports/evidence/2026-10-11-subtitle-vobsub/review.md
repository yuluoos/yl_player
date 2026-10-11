# One fresh-context read-only VobSub review

Reviewer gpt-6-astra/high. Base367c0bbbbabcb58bffcae0d47be44cd4dd749ea0;
12 owned candidate source/test files and documentation. Existing65-test evidence
inspected; no source/index/HEAD mutations or duplicated suite. Reviewer found
bounded pair ownership, independent substream assembly, control/RLE semantics
and reuse of image lifecycle sound.

## Findings and executor grading

Critical:0. Important:2. Minor:1 (regraded required consistency fix). No deferred
minor or second review.

1. PES low flags rejected ordinary P-STD extension. dvdauthor subgen.c emits
   PTS+extension flags0x81, length8, five PTS bytes then1e603a. Accepted Important:
   supported DVD images must not fail solely because of this routine framing.
   Parse/validate exactly bounded P-STD extension and stuffing; other extensions
   remain unsupported. Success asserts identical RGBA/timing; four invalid header
   variants reject as malformed rather than blanket unsupported.
2. Terminal SPU cursor equality rejected dvdauthor's one END(0xff) byte added
   to align odd packet lengths. Accepted Important: allow exactly one byte only
   after a self-linked final sequence, at odd cursor/even declared length.
   Preserve rejection of arbitrary bytes, two bytes and padding an even unit.
3. First index signature line skipped2048-code-unit check. Confirmed by executor
   self-check and reviewer Minor. Regraded for consistency with the explicit
   per-line resource contract; overall4MiB limit always remained intact, so this
   is not presented as unbounded memory exposure. Add first-row check.

RED: header-budget-red.log0pass/1fail; review-red.log54pass/7fail (two valid
producer variants, header bound and four error-classification checks). Single
fix pass; final directed and four-package results recorded in manifest.

Producer evidence (inspected, no code/assets vendored):
- https://github.com/ldo/dvdauthor/blob/master/src/subgen.c
- https://github.com/ldo/dvdauthor/blob/master/src/subgen-encode.c

## Declined-to-judge rulings

- Embedded/native subtitles, cross-Period identities and multi-audio remain
  separate tasks. Cost: this external pair slice adds no guarantees there.
- HDR brightness, protected/DRM output and physical external-display behavior
  remain unaccepted. Cost: local Flutter pixels cannot qualify those surfaces.
- Prior ASS/font behavior and PD-03 video-survival/public image-failure event
  policy remain unchanged. Cost: no new recovery/event-policy qualification.
- MPEG1/HD/archive/CHG_COLCON stay explicitly excluded. Cost: advanced valid
  material remains unsupported, not rendered approximately.
- Shared/overlapping field data, unused PXD gaps and multiple complete units for
  the same substream in one pack remain strict compatibility limits; reviewer
  lacked ordinary-producer evidence to grade them. Executor records these in
  the spec. Cost: such legal encodings may reject and require a later expansion.
- Foreign long-play/weak-network ABR remain excluded. Native audit/license
  qualification was not repeated by reviewer; executor separately matched all
  prior pinned artifact hashes and added no dependencies. Cost: no native codec,
  whole-RSS or device qualification is claimed by these tests.

Reviewer verdict: ready with fixes. One regression/fix pass, no re-review.
