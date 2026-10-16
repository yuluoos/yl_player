# Single fresh-context final review

Reviewer: `/root/p03_pcm_final_review`, GPT-6-astra, no inherited turn history. Base `094d7524eab956ca10f3b7af969ad6e347838524`; reviewed the full uncommitted PCM follow-up with its approved Task 7 scope and documented limits. Final runtime/artifact checks were explicitly pending when dispatched; no completed-check claim depended on this review.

## Important: DASH timestamp owner

Dolby/DTS/FLAC converters defaulted a nil presentation floor to zero. DASH intentionally registers the original mapped packet PTS and applies its own rational window after decoding. A −5000us Dolby packet now returned 0us, causing `decoder.dash_audio_invalid`; fully discarded packets could retain map entries until the 256-entry bound. Preserve PTS without an explicit floor, and make ordinary demux supply zero explicitly. Add actual compressed-packet partial/full-preroll regression.

No other Critical/Important or actionable Minor findings. Reviewer inspected native bounds/reset/layout, trim arithmetic and allocation ownership, Android manual skip, reference generation and switching assertions; checked fixture copies/hash identity and whitespace. Readiness was conditional on this fix and the pending final verification, not full P03/physical qualification.

## One fix pass

`dash-owner-red-summary.json` records the added real-converter test failing before the fix. Dolby/DTS/FLAC now preserve packet PTS/PCM when `presentationStartUs` is absent; ordinary demux passes a nonnegative explicit initial/seek floor. The same test passes in `macos-final3-summary.json`, including all four controls and 260 completely clipped packets per control beyond the DASH map's 256-entry limit. Final macOS affected suite: 74 passed, zero failed/skipped. iOS verification and the final evidence identities are recorded in the archive README. No second reviewer or waived finding.

