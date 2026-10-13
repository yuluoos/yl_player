Read-only review: **2 Important findings; no Critical or Minor findings.**

1. **Important — same-session live reconnect resets audio selection.**
   `YlAvPlayerBackend.swift:1558–1560`, called by `scheduleLiveReconnect` at line 1594. The new default teardown resets both the identity registry and `selectedAudioTrackId`. Reproduce by selecting a nondefault ordinary live HLS audio track, then triggering a retryable reconnect: the rebuilt item receives fresh IDs and platform-default selection. Preserve audio identity during reconnect and add a focused retention test.

2. **Important — missing audible group bypasses selected-identity failure.**
   `YlAvPlayerBackend.swift:1365–1368`. During generic asset restoration, a preserved selected ID with `audioGroup == nil` silently publishes an empty catalog. This contradicts the frozen contract requiring an explicit error when selected identity cannot be restored. Reproduce by selecting audio, deactivating, and restoring an updated asset without an audible group. Report `track.not_found` for the preserved selection; retain successful empty catalogs for fresh sources without a selection.

Reviewed compiler identity construction, duplicate rejection, Period matching, rendition mapping, budgets/credential integration, backend lifecycle, API comments, and new tests. `git diff --check` passed. Inspected macOS summary reports 165 passed, zero skipped; did not rerun suites.

**Declined to judge:**

- Final iOS/public results and final evidence/source fingerprint consistency, still pending.
- Physical audible switching, minimum OS, devices, longplay, weak-network ABR.
- P02 subtitle lifecycle, resource/rendering budgets, HDR/DRM/external-output behavior and PD-03.
- Full P02/cross-platform completion and unrelated pre-existing fixture drift.
