# Candidate AAC initial preroll correction — 2026-10-09

Base8f65fe6. User continuation authorizes this bounded production correction;
retain default-disabled/non-commercial scope. Reuse codex/fel-integration.
Root cause: real firstPCM PTS-21000us triggers candidate compatibility fallback.

Only an eligible AAC candidate before any accepted/submitted PCM may trim an
initial negative prefix bounded by one actual PCM block (<=1024frames,48kHz,
Float32 planar stereo). Decode first, ceil(-PTS*48000/1e6) frames trimmed from
both channels in place. Keep allocation/reservation bytes unchanged; recompute
PTS/duration from retained frames. Fully pre-zero blocks release and return
buffered without output/anchor; unsupported/malformed/later negatives keep
existing compatibility fallback. Never simply clamp timestamps or drop an
entire partial block. Legacy/iOS/bounded routes remain unchanged.

Plan: content-based RED/GREEN regressions for partial/full/rounding/range/later
negative and legacy; full macOS native + iOS arm64 compile for shared change;
fresh review and fixes; frozen30s realdecode short gate. Long arm only if exact
same-version short passes; preserve any failure and never relax thresholds.
Preserve first3actual PCM metadata; default/productionAdmission/bound false.
The existing decoded protocol's timing/short/long bounds remain binding. Its
prior test-only scope is superseded here for this production correction.

Ruling: retain allocated bytes after in-place trim (capacity still1024), rather
than falsely lowering ownership to retained payload length. Costs conservative
short-lived budget charge; no extraPCM allocation. Millisecond packet timestamp
quantization is preserved for subsequent packets, without inventing a global
rebase or codec-delay metadata. Trim boundary rounds upward to exclude samples
before zero, at most one sample past the mathematical boundary.

Review: oneImportant repeated complete-negative discard, fixed with operations-
locked terminalPrerollConsumed reset on eligibility/flush. Actual regression
RED1/1; final full suite must include GREEN. OneMinor duration coverage added. Both
consumed-state reset and duration333/21312us tested. Initial four tests RED2/4,
pre-review audio71/71; preserve these identities separately from final runs.
