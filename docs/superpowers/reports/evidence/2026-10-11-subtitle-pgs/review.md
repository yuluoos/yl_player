# One independent read-only PGS review

Reviewer: fresh-context gpt-6-astra / high. Candidate: 11 owned source/test
files over 1a20e5dc488b0f4a129db8ab4b26b5f7e3f5f16c, plus PGS documentation.
The reviewer inspected the parser/runtime/overlay and plan Review Focus;
no source/index/HEAD mutations or duplicate suite run. Directed evidence 58/58.

## Findings

Critical: none. Important: one. Minor: none.

**PGS source mapping did not account for viewport clipping of fitted destination.**
`text_subtitle_overlay.dart` used the intersected aperture size but normalized
source from the uncut fitted source. Valid Alignment outside [-1,1] could
compress rather than clip the bitmap. For 100-square input, 300x200 output,
contain and Alignment(2,0), video x150..350 is clipped at300: bitmap x20,width4
should map to x190..198, but mapped to x180..186.

Executor accepts Important. Add left/right/top/bottom fixed-pixel regressions,
observe RED, retain original fitted destination and map the visible intersection
back into source coordinates. One fix pass; final verification recorded in the
manifest. No second review.

## Declined-to-judge rulings

Each reviewer decline remains outside this slice; none is silently accepted as
completed product behavior:

- Cross-Period/native track identity and duplicate IDs belong to Task1, unchanged.
  Cost: no new assurance for those native selection cases.
- Embedded PGS, VobSub and excluded SUP plane semantics remain explicitly rejected
  or outside opt-in. Cost: some valid disc subtitles remain unsupported.
- Advanced ASS/fonts are prior slice scope. Cost: its documented limits remain.
- Playback recovery/engine-image public event mapping remains PD-03; current
  sanitized Flutter error and partial-image cleanup were reviewed. Cost: no new
  public player recovery/event semantics on engine image failure.
- HDR/protected output, reconnect and physical synchronization lack device
  acceptance. Cost: ordinary local Flutter evidence must not qualify those paths.
- Native rebuild not performed; executor checked all prior artifact hashes.
  Cost: no PGS native codec capability or device certification claimed.
- RSS/engine temporary copies are not guaranteed by cache/job limits. Cost:
  measured process memory qualification remains separate work.
- Other task's long-play/weak-network ABR changes are excluded by user request.
  Cost: no new validation of those changes from this slice.

Review verdict: ready with the geometry fix. Parser preallocation limits,
atomic replacement, bounded job scheduling and late-image disposal were judged
coherent. Reference cross-check: FFmpeg n8.0 libavcodec/pgssubdec.c.
