# One fresh-context final review — fMP4 wvtt/stpp

Reviewer gpt-6-astra/high, read-only, no subagents or second review. Baseabf1eab,
owned candidate only; benchmark dirt excluded. Read four-package1299/1299 log,
did not rerun author tests. No checkout/index/HEAD mutations.

## Findings and verdict

Critical0 Important0 Minor0 newly found. Ready to commit after final verification.
No blocking fix pass was required. Prior wvtt nested-box aggregate accounting Minor
continues to be documented; this review found no new impact.

Strengths: trex/tfhd/trun precedence preserves zero values; consistent bases,
signed offsets,64-bit boxes/tfdt; extracted sample helper preserves nonfragmented
semantics and TTML composition/edit/region behavior; cross-fragment budgets and
extent checks; unchanged managed transport/atomic publication; realfile/HTTP/
Flutter rendering and lifecycle evidence.

## Declined-to-judge rulings

Executor accepts each exclusion for these reasons and costs; wholeP02 stays open.

1. Later traf implicit base: documented subset requires explicit/moof base, avoiding
   inference from skipped video bytes. Cost: some legal BMFF layouts reject.
2. Mandatory tfdt/increasing mfhd/nonoverlapping decode time: deterministic bounded
   subset, not full BMFF conformance. Cost: otherwise legal omitted/reset timing rejects.
3. Separate init/media URLs, manifests/live/crossPeriod: current API scans one complete
   resource; TrackID remains independent of array index. Separate workflow still needed.
4. Fragmentedtx3g/hybrid/encrypted/auxiliary data: explicit rejection avoids misdecoding
   and implicit resource requests. Such content needs a later slice.
5. Incomplete validation of audio/video traf payload/trun: subtitle reader deliberately
   skips unrelated payloads, validates subtitle extents itself. No AV validator claim.
6. Nestedwvttbox200000 counter: prior trueMinor remains deferred;4MiB/local-child limits
   still bound this work. No newly demonstrated budget bypass or increased severity.
7. Overlapping subtitle extents rejected after parsing: no partial publication; all
   preceding work is globally bounded. Earlier rejection optimization not required.
8. Negative offset not duplicated in newwidgettest: sharedowner unchanged and existing
   session/runtime negative-offset cases run in fullsuite; positiveoffset/seek/off/late
   cancellation have newfragment coverage. No new negative-offset defect identified.
9. No third-party producer positive fixture: ownedtestbuilder/realIO evidence only,
   openly documented; producer interoperability remains unqualified.
10. Fonts/bitmap/ASS/HDR/DRM/externaldisplay/PD03: unchanged strictsubset; no physical
    or recovery-policy acceptance. This slice cannot close these broader P02 rows.

Final suite, analysis, artifact hashes, source/reference equality and scoped commit
verification are executor-owned evidence in manifest.json. Braces-only lint fixes
were completed before final verification; no post-review semantic changes.
