# One final fresh-context review — hybrid MP4

Read-only gpt-6-astra/high, no subagents, no mutations or repeated author tests.
Reviewed entire production diff,40newtests, inherited runtime/managed paths and
contract againsta9673dc. Ninecandidate files hash-equal isolatedsnapshot;
40/40directed,1382/1382fourpackages,Noissues and clean diff-check confirmed.
Critical0 Important0 Minor0new; ready to commit, no fixpass/secondreview.

Strengths: decode floor from pertrackstts ratherthanctts/edit/visiblecue; shared
initial/fragment extents validated acrosssubtitletracks before return; budgets,
TTMLsourcebytes/ordinals/packets do not reset; runtime atomic publication remains
after all I/O/limits/cancel checks. Both guardmutations detected by regression
failures. IndependentFFmpeg,3codec fixtures, realIO and actualFlutter rendering.

## Executor rulings on every considered/declined behavior

1. Identity/Period: TrackID stable through initial+fragments, no arrayrebinding.
   CrossPeriod/live/manifest scope staysopen; duplicateIDs remain rejected rather
   than recovered. Cost: those sources need a later identity/discovery slice.
2. Lifecycle/negativeoffset: existingowner unchanged; newhybridtransition/seek/off/
   offset/latecancel evidence plus prior shared negativeoffset tests in fullsuite.
   No new negative-offset defect demonstrated; no duplicate case required.
3. PD03: discovery failures preserve catalog/selection/video state as before;
   this is isolation, not a new final video recovery decision. PD03 remainsopen.
4. Budgets: shared initial/later sample count also bounds extent storage; earlier
   nestedwvtt structuralcounterMinor staysdeferred with local/payload bounds.
   No new risk demonstrated or generalized RSS guarantee.
5. HDR/DRM/externaldisplay/native/device: Flutterregiongeometry evidenced only.
   Physical/renderprotection/synchronization acceptance remainsopen.
6. Initonlymvex/emptyzerosample/description/CTO: conform to explicitboundedcontract;
   inherited tfdt/trex/addressing requirements remain deliberate compatibility
   limitations. No implied completeISO/MSEsupport.
7. AVbytealias/video-source-version/growingresources/separateURLs/RSS: not implemented
   or claimed, explicitspecboundaries. Currentreader checks subtitleextents and
   its own stableHTTPresource; other guarantees require separatework.
8. FFmpegtiming/producer: encodedfirstend3.123s is correct reference, inputSRT2.5s
   is not containerfact. Independentproducer coverage is tx3gonly; wvtt/stpp
   positive evidence remains ownedbuilder tests, no broadinterop claim.

All exclusions accepted with above costs, wholeP02 remainsopen. Executor freezes
permanentlogs/fixtureinput/probe/artifactaudit/hashmanifest before scopedcommit.
