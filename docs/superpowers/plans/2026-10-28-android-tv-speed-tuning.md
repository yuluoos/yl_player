# Android TV playback speed tuning

> **For agentic workers:** Use superpowers:executing-plans. Execute the already authorized changes in this chat, then request a whole-change review.

**Goal:** Improve low-end Android network VOD playback at 1.5x without lifting compressed-media byte targets or forcing unverified vendor codec modes.

**Architecture:** Keep Media3 1.11.0 and the existing decoder/output ownership. Scale VOD loading duration by speed (at most 2x) while the existing allocator byte target remains authoritative. Give constrained TVs a bounded PCM scheduling cushion and add rate-limited numerical diagnostics to distinguish buffering, dropped frames and audio underruns.

**Tech Stack:** Kotlin, Android API24+, Media3 1.11.0, existing JVM tests under JDK17.

**Spec:** User-approved chat proposal: optimize cloud-drive playback at 1.5x, with low-end memory and compatibility taking priority. No local comparison/device logs available.

## Global constraints

- Preserve compressed-media byte targets, pressure reductions, decoder policy, user speed, selected tracks and timeline.
- Unknown/live/ad timelines retain existing loading duration semantics. VOD time scaling is capped at 2x; slower speeds retain existing targets.
- Audio extra allocation above Media3's normal PCM size is at most 256 KiB, aligned to whole frames. Never undercut platform minimum or alter passthrough/offload sizing.
- No new dependencies, schema changes, global async queue forcing, platform audio speed forcing, or silent quality/speed downgrade.
- Diagnostics retain at most one numeric previous sample and one transfer measurement, emit at most once per 10 seconds during active >1x playback with new symptoms, and contain no locators/headers/exception prose.
- Default codec behavior remains until physical legacy-TV A/B results justify changing it. Existing adaptive track selection remains available; fixed files cannot be transcoded by these changes.

## Review focus

- Bytes reached before duration: loading stops, including under pressure and at high speed.
- Live/unknown/ad timeline: no extra live backlog or timeline movement.
- High-channel/high-rate PCM: bounded overhead, whole frames and minimum sizing preserved.
- Protected/DASH/non-TV output: preserve existing AudioSink wrapping and defaults.
- Repeated/stale analytics: no log flood or URL disclosure; no new playback actions.

## Task 1: VOD duration targets

Files: `YlAdaptiveLoadControl.kt`, `YlAdaptiveLoadControlTest.kt` under the Android main/test Kotlin directories.

- [x] Add failing callback-level tests: 15s media at 1.5x still loads; 22.5s stops; 1x/slow unchanged; 4x stops at 30s; bytes/pressure win; live, unknown, ads unchanged.
- [x] Scale only the loading duration comparison using the loading period's timeline classification. Reuse period/window objects on the playback thread.
- [x] Run targeted tests and confirm behavior; no allocator target changes on speed switches.

## Task 2: bounded TV PCM cushion

Files: new `YlTvAudioBufferSizeProvider.kt` and test; `YlOutputRenderersFactory.kt`, `YlMedia3Core.kt` and integration tests.

- [x] Test real provider outputs for 48kHz stereo PCM (750ms), high channel/rate limits, required minimum, passthrough and offload identity.
- [x] Implement a provider wrapping Media3 defaults and a 750ms target, limiting additional PCM bytes to 256 KiB aligned down to complete frames.
- [x] Enable only constrained clear non-DASH TVs. Preserve default speed processing, AudioOutput parameters and all other sink setup.
- [x] Verify production factory wiring and excluded paths with boundary tests.

## Task 3: bounded speed diagnostics

Files: new `YlPlaybackSpeedDiagnostics.kt` and test; `YlMedia3Core.kt` plus core tests.

- [x] Test first symptomatic emission, 10s throttle, stable counters, session reset, speed=1/paused inactivity, safe writer failure.
- [x] Sample numeric buffer media/playout duration, allocator bytes/target, speed, tunneling requested, cumulative rebuffer/dropped/underrun counts on existing ticker; never include source data.
- [x] Verify actual core ticker wiring and ensure no pause/seek/speed changes.

## Acceptance

- [x] Run Android JVM suite with JDK17, inspect XML totals and existing skips.
- [x] Review whole diff, address substantive findings, run affected tests after fixes.
- [x] Update Android README with behavior and actual device acceptance matrix (local/network at 1x/1.5x, pause/seek/speed restore, memory).
- [x] Report no measured TV performance claim; async codec changes require device evidence.

## Execution record

- Working in a fresh local branch from a clean checkout; no worktree relocation to avoid copying existing native/build fixtures.
- User has explicitly authorized execution. No additional plan approval needed.

- Baseline JVM suite succeeded with JDK17 (`/tmp/yl-tv-speed-baseline.log`).
- VOD callback regression: 6 tests, 2 expected assertion failures before the change, then buffer suites green. New provider/diagnostics API tests first failed compilation until their types were implemented; their behavior and wiring tests subsequently passed.
- Diagnostic wiring test initially had a Mockito nested-stubbing fixture error. After fixing the fixture, removed the ticker wiring temporarily and observed the intended assertion failure (expected one report, got zero), restored wiring, and reran the suite.
- Final JDK17 JVM suite: 596 tests, 0 failures, 0 errors, 3 existing skips (593 passed); `/tmp/yl-tv-speed-final-jdk17.log`. Added 21 focused tests.
- Independent read-only review found no blocking production defect; `git diff --check` passed.
- No connected Android devices were available. No measured performance, native memory, driver stability or physical playback claims. No forced asynchronous queue mode or platform AudioTrack speed processing; these remain device-qualification work.
- Changes remain uncommitted on `codex/android-tv-speed-tuning` for review.


## Follow-up: three approved refinements (2026-10-28)

User explicitly requested all implementation first, then consolidated testing and
independent review. This supersedes per-task review/full-suite cadence. Preserve
first-round changes and evidence; no additional commit/push authorization.

- Actual decoder rendered/dropped counters replace estimated frame counts. Preserve
  totals across renderer replacement; pause resets observation, ongoing buffering
  remains a separate health input without repeatedly charging prior windows.
- Positive Android memoryClass adds a downward-only heap/8 byte target cap to all
  profile paths. Unknown heap retains prior targets; memory-pressure restore cannot
  lift the cap. Allow nonempty buffered playback at the full byte target to avoid
  a load/start deadlock when the smaller cap cannot reach the duration threshold.
- Rate-limited diagnostics distinguish full allocator budgets, recent observed
  transfer below video demand, idle loading and unknown evidence. One prior numeric
  sample measures buffer trend/consumption; no new polling, dependencies or actions.
- Do not increase rebuffer duration thresholds, force async codec mode, change
  platform audio speed handling or claim a measured TV performance improvement.

Status: implementation and consolidated local verification complete; physical
MT8176/MT9652/32-bit TV acceptance remains unverified (no connected devices).

Consolidated evidence for the uncommitted working tree over `53f9cb0e`:

- First run: JDK17 `:yl_player_android:testDebugUnitTest --offline`, 613 tests,
  1 failure, 0 errors, 3 skips. All 17 newly added follow-up cases passed.
  Log: `/tmp/yl-tv-speed-refinements-jdk17.log`; original XML retained in
  `/tmp/yl-tv-speed-refinements-first-results/`.
- The sole failure was an existing assertion searching the entire diagnostic line
  for `599`, which can match the generated UUID. Scoped it to `httpStatus=599`;
  assertions for actual 503/404 responses and private request data remain intact.
- Final complete rerun with the same JDK17 command: exit 0, 613 tests, 0 failures,
  0 errors, 3 skips (610 passed). Log:
  `/tmp/yl-tv-speed-refinements-final-jdk17.log`. The three existing skipped cases
  are RTMP independent MediaMTX peer acceptance cases; they were not executed.
- One independent comprehensive read-only review covered all tracked/untracked
  changes, low-memory/codec/live/DRM boundaries and the test assertion fix. No
  substantive defect found. Reviewer reused final evidence and verified cached
  Media3 1.11.0 counter synchronization and default AudioSink configuration.
- `git diff --check` passed. `adb devices -l` returned no connected device.
- No dependency/schema/shared Dart changes. This JVM result establishes regression
  coverage, not measured throughput, native memory or physical TV compatibility.
  User subsequently authorized committing this reviewed snapshot. No push or merge
  is included in that authorization; no production/test code changed after acceptance.
