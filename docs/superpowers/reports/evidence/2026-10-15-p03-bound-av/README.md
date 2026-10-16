# P03 same-run product-bound native A/V evidence

Base: `7a77ede74469550041eab8a249e21c95b5f1bbbe`. This is a bounded continuation of approved P03 Task 7, not full P03, public Flutter/release-app, physical output or sustained thermal qualification. P05 long-play/weak-network ABR was not changed or run.

## Identity and observations

The host freezes real built artifacts before launch; native tests verify actual installed bundle/APK bytes and media before playback; host artifacts are compared again afterward. Apple product and XCTest bundle have separate canonical file-manifest hashes, and loaded product images must match frozen file hashes. Android explicitly uses an **instrumented library APK**, containing both production Kotlin/JNI and tests; both identity roles therefore use the same APK hash. A source revision alone is never substituted for executable identity.

Each control has one new player/session ID. The same player produces actual center pixels, native audio-output-derived programme clock observations, decoded/trimmed PCM, completion and three seeks (1.25 s, 2.25 s, 0). Raw Float32 PCM remains in `rows.json.gz`; the independent validator recomputes hashes, tones and channel/downmix identity, and checks repeated image/clock pairs. Each successful control contributes seven PCM windows of 8,192 frames. Apple observes the renderer clock; Android final records observe the fresh AudioTrack playback head; both production position extrapolation and wall-clock fallback are excluded. A stalled playback head cannot acquire consumption evidence from elapsed time. These clocks and decoder-boundary samples do not measure physical speaker/display latency.

The Android internal observer is optional and inactive in production. Its release observation is read only after disposal acknowledgement. Public Flutter APIs, decoder admission policy and actual playback semantics are unchanged. Native test APIs and collectors document identity, ownership and scope.

## Results

| Runtime | Required controls | Accepted raw A/V rows | Whole frozen scope |
|---|---:|---:|---|
| macOS M1 / 26A434 (`macos-final`) | 6 | 6 | passed; native 6/6, artifacts unchanged |
| Android API 36 arm64 cold boot (`android-final`) | 6 | 5 | failed; VP9 hardware-required route unavailable |
| iOS dedicated simulator (`ios-final`) | 6 | 0 | failed; six identity-verified decoder-unavailable rows, no skips |

macOS run `d772ddea-e753-40f4-b71e-9c9c786e798c` product manifest `350b9581a695e491fd871275675c85c6a718eb69bbe1a185eb7444efe8c829df`, test manifest `500f922cabd6f0c95216f0b5513aaf93ec7387d85c97e1e1c967f01447d21ef5`.

Final Android consumption-clock run `98991c38-97f2-4b6b-9c7b-151a39e7e6a1`, APK `546b2de9e851adf78f4d7d895525d4f3e4d5655e324c33906f394da2d333ef05`: five raw A/V rows pass, VP9 remains required/unavailable, whole scope fails.

Historical Android run `cbab06e8-3c16-4480-858d-0966fc5eea33` (anchored estimator, superseded for consumption evidence), APK `0840a361a7e00eaeb05296b3e7a3a22c452474b1898236a8e6bf50c940ce0d86`. Its E-AC-3, DTS, FLAC, AC-3 5.1 downmix and PS/MP3 rows pass. VP9 is retained as `DECODER_UNAVAILABLE`; five rows are not promoted to a six-control pass. This does not assert VP9 is unsupported by the separate Media3 route.

`macos-negative`, `android-negative2` and `android-final-negative` deliberately supply an incorrect build hash. Actual native execution rejects it before playback: zero accepted rows. Python negative controls reject borrowed run/build/test/media/session identities, missing or duplicate rows/windows, malformed evidence, absent clocks, wrong images, silent/corrupt/nonfinite PCM and unobserved release.

## Failed attempts and environment

- `android-red` exposed a collector assumption that JNI always maps an extracted `.so`; this runtime maps library bytes directly from the APK. The installed APK remains the product identity.
- `android-clock-red2` observes real PCM/images then fails the missing-native-clock assertion; wiring the optional AudioTrack observer addresses that implementation gap.
- Snapshot-restored Android runs (`android-clock-red`, `android-attempt1`, `android-attempt2`) stall near 0.52 seconds. AudioService/AudioFlinger diagnostics are retained. A foreground test activity and real app-managed focus alone did not fix it. Cold boot of the **same owned AVD with the same pre-review APK (0840a361…)** restores five complete controls; no decoder/output threshold was relaxed. The old snapshot is not overwritten.
- `android-negative` rejects the APK correctly but exposed `adb exec-out` returning zero with a missing-file diagnostic on stdout. The collector now preserves that output and reports failed extraction; unit regression ran RED→GREEN and `android-negative2` verifies the corrected behavior.
- `macos-attempt1` was successful before the final runtime-platform metadata check; it is not substituted for the final build.

## Review fix

One fresh read-only review found one Important issue: the initial Android observer recorded the production clock estimator rather than fresh consumed frames. A stalled head could still appear to advance during a short seek. `YlConsumedAudioClockTest` reproduces this before the fix; the new internal `consumedPositionUs` reads the actual head, does not alter the scheduling estimate, and invalidates on flush/close. Validator tests reject estimated/absent clock-method labels and stalled seek clocks. Historical `android-cold` raw rows are retained but **cannot pass the current consumption gate**. Final evidence is recollected from a newly built APK/run ID. No Critical or deferred Minor findings.

## Regression and remaining work

Media matrix Python: 44/44; catalog: 22 fixtures, 132 planned platform/transport rows (catalog consistency only). Android unit regression: 531 passed, 3 preexisting skips, zero failures; existing PCM/format native regression: 22/22. Apple collector compiles iOS/macOS. The Apple fixture helper suite has 40 passes and one preexisting mirror-drift error in three unrelated macOS files (`AppleHostCharacterizations.swift`, `YlDashResourceLoaderTests.swift`, `YlMacosPresentationTests.swift`); these files were left intact.

Still open: full public Flutter/release build-bound matrix, Media3 VP9 same-run audio capture, iOS hardware-positive output, physical A/V timing, complete independent-reference codec coverage and qualifying sustained thermal evidence. Production software admissions remain closed for unmeasured identities. Task 7's composite acceptance checkbox stays open.

See `tool/media_matrix/BOUND_AV.md` for build-once/run-without-building replay. Retain the exact plan, product/test manifests, launch, native log/summary, raw rows and result together. Large original executables and `.xcresult` remain local build artifacts; this archive retains their identities and extracted evidence. `manifest.json` hashes every archived file except itself.
