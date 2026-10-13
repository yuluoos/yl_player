# Fresh final review

Reviewer: fresh gpt-6-astra/high, read-only, no inherited conversation, one review.
Base: 01e65829930bc2acc9328de15018128b12322867. Candidate: 12 source/test/fixture
files byte-identical to validation snapshot. No fixes or repeat review.

## Completed reviewer report

### Strengths
- Small, coherent integration reuses the existing decoder, subtitle owner, managed reader and bitmap overlay.
- Embedded header handling preserves external IDX validation; packet timing, clipping and limits are explicit (`vobsub_parser.dart:523`).
- Remaining catalog bitmap budget reaches the decoder before allocation (`text_subtitle_runtime.dart:185`).
- Tests cover actual pixels, animation, timing, malformed-input atomicity, HTTP policy, cancellation and image disposal.
- All 12 reviewed candidate files match the validation snapshot. Logs confirm **1594 tests passed**, including **69 directed tests**, and **No issues found** from analysis.

### Issues
- Critical: None found.
- Important: None found.
- Minor: No new actionable findings.

### Recommendations
No additional implementation changes recommended for this slice. Preserve the tested candidate when committing.

### Declined to judge
- Advanced DVD commands, menus and nonneutral IDX transforms: explicitly excluded; reviewed rejection behavior only.
- Compression, encryption, lacing and other unsupported Matroska structures: inherited restricted demux contract.
- Nonunit TrackTimestampScale and broader legal Matroska compatibility: existing parser restrictions remain; this review does not certify universal container support.
- WebM/MP4 VobSub and unrelated subtitle codecs: outside this Matroska feature.
- Manifest/live/multiple-resource discovery, cross-Period and audio identity: excluded from the authorized slice.
- Native/device, HDR, protected-content and external-display equivalence: fake-backend/widget evidence cannot establish these properties.
- PD03 and final engine image-failure policy: existing open work, unchanged here.
- Total process/GPU peak memory: reviewed encoded and decoded catalog limits, not a whole-process memory guarantee.
- Prior MP4 WebVTT nested-box accounting Minor: unchanged, deferred scope.
- Long-play/weak-network ABR and unrelated changes: explicitly excluded.

### Assessment
Ready to merge? Yes. The implementation meets the scoped discovery, selection and rendering contract
without a new network or native path. No blocking defect was found; the matching candidate has
completed regression and static-analysis evidence.

## Implementer rulings for every declined scope

1. Advanced DVD/menu/nonneutral settings remain explicit unsupported failures, not silently degraded
   rendering. Accept this inherited bounded decoder contract; cost: some valid DVDs require later work.
2. Compression/encryption/lacing remain rejected by shared demux. Accept rejection without data loss;
   cost: broader Matroska compatibility is unclaimed.
3. Nonunit TrackTimestampScale remains rejected; TimestampScale and CodecDelay supported/tested.
   Accept inherited restriction; cost: legal nonunit per-track scale files remain unsupported.
4. WebM/MP4 VobSub remain unsupported. Accept codec-specific container boundary; cost: no universal
   embedded bitmap support despite common renderer.
5. Only one complete file or HTTP resource is scanned. Accept no manifest/live/Period/audio identity
   change; cost: full P02 still open.
6. Widget pixels and fake backend prove Dart behavior only. Accept no device/HDR/protected/external
   display claim; cost: separate native/device acceptance is still required.
7. PD03/engine image failure mapping unchanged. Accept no policy or bridge redesign; cost: those
   decisions remain open and cannot be inferred complete from this slice.
8. 4MiB encoded and 64MiB decoded catalog budgets are tested before publication/allocation, not total
   RSS/GPU bounds. Accept existing old/pending catalog and image lifetime model; cost: no peak-process
   memory guarantee.
9. Prior MP4 WVTT aggregate nested-box accounting Minor stays deferred in its original report.
   This VobSub work neither changes nor reclassifies it; cost: prior bounded structural caveat remains.
10. Long-play/weak ABR excluded as user requested; scoped commit contains no tool/benchmark/ABR
    changes. Accept independent work boundary; cost: no acceptance claim for the other task.

No new deferred minors; no second review or fix pass. API comments requested this turn are updated.
