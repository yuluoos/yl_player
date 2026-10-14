# One fresh final review

Reviewer: gpt-6-astra, read-only whole-range review, baseline c3e304e144f750b62983267023ae06953ead3458 through 83f92d6a16a1796014608768d1bed63a14ad0026. No second review.

## Strengths

Exact rational timing, bounded resource ownership, sticky credential ancestry, PCM clipping, and cancellation fencing are coherent. Validation distinguishes actual pixels/audio consumption from selection and physical output. Failed attempts, skips, and tooling limitations remain visible. Reviewer inspected the 19-commit range in source passes and verified all 416 final-validation and 71 joint-native manifest hash entries.

## Findings

Critical: none. Minor: none.

Important: Preserve Apple's accepted video family independently of the pipeline. At YlDashProgramBackend.swift:198/:399, replacement derives qualityFamily only from pipeline; deactivation clears it. Period 1 SDR followed by Period 2 with higher-bitrate HDR and lower-bitrate SDR restores into HDR. Seeking to programme end similarly removes the only stored family. This violates PD-02. Retain accepted family as backend/session state, initialize/update only on successful candidate commits, preserve through retirement/completion, and cover restore plus failed candidate preparation. Existing single-family restoration coverage misses this.

Recommendation: focused correction plus affected Apple suites. Recorded lipo adaptation, pre-existing mirror differences, conservative Dolby rejection, and local measurement envelopes are appropriately scoped.

Verdict before executor fix: Ready with fixes.

## Declined to judge

1. Physical iOS, minimum-OS runtime, Intel runtime, and physical speaker/display behavior: unavailable evidence, excluded from completion claims.
2. Long-play, weak-network ABR, and P05: outside approved scope.
3. Full DRM/Dolby display support and additional P03 codecs: excluded dependencies; unsupported paths rejected.
4. General DASH beyond the established admission subset, including multiple audio representations per AdaptationSet: restricted before BASE; approval targeted programme timing and necessary dependencies.
5. Repairing three pre-existing macOS mirror differences or installed lipo implementation: unrelated ownership/toolchain issues; scoped verification/limitations recorded.

## Executor grading

Important retained: background/foreground can visibly change SDR/HDR without a user selection, violating an explicit approved rule. One fix pass uses real PQ-tagged owned media and RED→GREEN native tests. No deferred minor findings. The five declined items remain explicit boundaries, each ruled on in the final report and ledger.
