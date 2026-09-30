# Playback measurements

## macOS paused display-layer readback

From `packages/yl_player/example`, run:

```sh
flutter test integration_test/display_readback_test.dart -d macos --no-pub \
  --dart-define=YL_DISPLAY_RUN_ID=display-owned-001
flutter test --no-pub test/display_markers_test.dart
```

Use a fresh nonsecret run ID, retain the complete log (including failed/skipped
rows), and record the checkout/source/config/dependency/media hashes before a
run, as in `macos-display-readback-observations.json`. This explicit Debug-only
example channel uses macOS 14.4+ `AVSampleBufferVideoRenderer.displayedPixelBuffer()`;
unsupported systems fail the probe without changing package deployment targets.
It traverses only the example window, requires exactly one display layer, and
does not capture the screen or protected content. The channel does not exist in
profile/release builds and does not change the production player package.

Three predeclared attempts play the owned `benchmark_sdr.mkv`; each pauses at
media positions at least 0.25/1.25/2.25/3.25 seconds. The API requires a paused
renderer. Each readback converts the displayed buffer through Core Image into
sRGB RGBA8 and checks nine interior points against red/green/blue/white in order
(maximum channel error 24/255). Unknown/blank pixels never become valid markers;
all four are required. There must be no layer before creation and after disposal.
No-image/no-layer observations are retained. Ambiguous output, timeout and
cleanup failures fail the attempt and skip subsequent attempts. Known readbacks
are emitted before cleanup as `YL_DISPLAY_OBSERVATION`; final identities use
`YL_DISPLAY_ROW`. A missing final row is incomplete evidence, never a pass.

`firstReadbackDelayUs` includes deliberate playback, pause, polling, channel and
pixel-copy overhead. It is **not first-frame latency** and is not fed into the
latency summarizer or any SLO. This proves a paused display-layer buffer's coarse
color content, not compositor presentation, physical scanout, monitor color
accuracy, spatial geometry, audio output, synchronization, HDR or Dolby Vision.
The final run has 12 matching marker frames (108 RGB points) and six retained
pending observations across three attempts; foreground activation still failed.

The separate owned fixture explicitly transforms BT.601 lavfi pixels to BT.709
and signals matrix, primaries, transfer and limited range. Its committed identity
and independent host FFmpeg checks are in the evidence JSON. The generator
`generate_display_fixture.py` refuses to overwrite an existing fixture; generating
a replacement requires moving the old file aside and creates a new evidence
identity. The original format-matrix fixture had unspecified color metadata and
failed the original fixed tolerance; that run remains a recorded gap. The new
fixture does not establish that untagged-content color interpretation is fixed.

Cleanup independently attempts disposal, view removal, post-removal inspection
and temporary-file deletion, with a five-second deadline for each step. An
exception or timeout does not skip later steps. Creation without a confirmed
handoff keeps `cleaned=false`, even if independent cleanup succeeds; the creation
helper continues to own late instances. Late completion never upgrades a recorded
timeout or resumes subsequent attempts. `cleaned=false` means cleanup could not
be confirmed, not proof of a permanent leak. The two original failure-path
limitations are covered by `test/display_cleanup_test.dart`; final regression
evidence is in `macos-display-cleanup-observations.json`. See P08 report.

## macOS process resources (instrumentation smoke)

From the repository root, choose a **new** output directory:

```sh
python3 -B tool/playback_benchmark/run_resources.py /private/tmp/yl-resource-run
# Optional second argument: absolute path to the Flutter executable.
python3 -B tool/playback_benchmark/resources.py /private/tmp/yl-resource-run/observations.jsonl
```

This explicit runner builds a test-only native sampler, embeds its bytes using a
Dart define, and loads it from the app's own temporary container. It does not
change app sandbox entitlements or link the sampler into the shipped package.
The library is loaded once and reused across three predeclared attempts in one
app process. The test requires macOS, Xcode tools and the example's existing
dependencies; it is not part of the unconfigured integration-test entry point.
`flutter test test/resource_series_test.dart` runs the injected sampler and
creation-lifetime unit tests without loading the dylib.

The owned four-second `format_matrix/mkv-avc-aac.mkv` runs through the public
player with app-managed audio. Each attempt observes two seconds idle, opening
through public first-frame receipt, playing until media position reaches two
seconds, disposal, and two seconds after disposal. The playing window is not
necessarily two wall-clock seconds. Recorded engine/decoder, geometry, selected
audio and continuing timeline validate the measurement path; physical picture,
audio and display presentation remain unverified.

Native samples use monotonic microseconds, cumulative self-process user+system
CPU microseconds, RSS bytes and physical footprint bytes. Nominal cadence is
250 ms; actual timestamps determine intervals. CPU 100% means one core and can
exceed 100%. Per-phase means are weighted by observed elapsed time; missing
samples and phase boundaries break CPU intervals. A singleton has unknown CPU,
not zero. The summary retains each phase's sample count/window, covered CPU
duration, memory first/last/peak, unavailable points, and all trial outcomes.
It rejects counter resets, backward phases/clocks and incomplete/mixed runs.
System thermal state is not a temperature; power/thermal unknown values remain
explicit. Temperature, GPU and media-ledger memory are unmeasured (`null`).

Creation has a ten-second deadline and late instances retain bounded disposal
ownership. Load/play/first-frame/disposal have local deadlines; failure or
timeout aborts later playback while emitting skipped identities. The app test
has a four-minute outer timeout; the wrapper has a ten-minute build/run deadline
and terminates only its owned process group. Build/setup/outer timeout failures
retain logs and a failed result, never a zero-sample success. They may lack final
trial rows; incomplete evidence must not be treated as passed.

The fresh output directory retains raw playback/build logs, JSONL, result JSON,
source and build-config hashes (including Podfile.lock, project/xcconfig/podspec,
entitlements and manifests), dependency/artifact/media/sampler identity, and
device/OS. `sourceHash` covers the recorded path map, not all external SDK/tool
binaries or ignored generated caches. Failed and intermediate runs remain
separate; never rewrite an old result's hashes to match later edits.

These are whole **debug-process** observations, including Flutter, the test
runner and sampling overhead. Cache state is uncontrolled; early/late trials
can reflect warmup and allocator retention. RSS and physical footprint are
distinct; a short post-dispose observation cannot prove absence of leaks or
require RSS to return to its initial value. No steady-state, long-run growth,
formal performance baseline, decoder-only cost, SLO or software-decoder budget
is admitted. Both admission flags stay false. See the checked-in
`macos-resource-observations.json` and the P08 report for the measured slice.

## First-frame event receipt

The first slice measures **public FirstFrame event receipt**, from immediately
before calling public `Load`, in one Dart monotonic clock. It does not subtract a
native `occurredAt` epoch from a Dart timestamp. Events arriving before Load
returns are retained and matched to the returned session; stale/duplicate events
cannot move the first observation. Player creation, copying the owned file and
mounting the view happen before the interval. Play is requested immediately after
Load, so the interval includes the public command round trip.

This is **not physical screen scanout latency**. The current Apple AVPlayer path
publishes a texture before emitting its event; that event is not a Flutter
compositor presentation acknowledgement. The smoke can verify instrumentation
and continued playback, not visual/audio quality, a formal performance baseline,
or REQ-14 completion. Do not present these numbers as an optimization gain.

## Run tests

From repository root:

```sh
python3 -B -m unittest discover -s tool/playback_benchmark -p 'test_*.py'
cd packages/yl_player/example
flutter test test/first_frame_probe_test.dart
```

`tool/check_foundation.sh` also discovers the Python tests. The ordinary example
suite discovers the Dart probe tests.

## Input and identities

`summarize.py INPUT.jsonl` accepts one complete run with identical conditions.
Different devices, sources, builds, cache/thermal conditions or runs must be
summarized separately. It rejects missing/duplicate attempts, duplicate JSON
keys, nonfinite numbers, unexpected fields, unsafe labels, and invalid hashes.
Inputs are bounded to 10,000 rows and 16 KiB per row. Invalid input exits 2 with a
safe message, no input echo/traceback, and no partial summary.

The Dart runner validates its complete condition allowlist before logging or
assertions can echo supplied values. Invalid input raises a generic safe error.

Required fields (no additional fields are accepted):

| Fields | Meaning |
|---|---|
| schemaVersion | Integer `1` |
| runId, caseId | Nonsecret identifiers for one run and owned media case |
| commit | Full 40-character lowercase Git SHA |
| sourceHash | SHA-256 of a canonical sorted relative-path → source-file-SHA map, including uncommitted code and test helpers (exclude generated caches for future baseline runs) |
| dependencyHash, artifactHash | SHA-256 of corresponding lock/config and native binary identity maps; retain the maps with evidence |
| mediaHash | SHA-256 of the actual input media bytes |
| platform | `android`, `ios`, `macos` |
| device, os, architecture, output, networkProfile | Explicit nonsecret labels; unknown output must not be described as a verified screen |
| deviceKind | `physical`, `simulator`, `emulator` |
| buildMode | `debug`, `profile`, `release` |
| power | `ac`, `battery`, `unknown` |
| thermal | `nominal`, `fair`, `serious`, `critical`, `unknown` |
| cacheState | `cold-controlled`, `warm`, `os-cache-uncontrolled` |
| measurement | `load-to-public-first-frame-event` |
| purpose | `smoke` or `baseline` |
| baselineComparable | Boolean; whether this media path was playable before optimization, not proof that this run is a baseline |
| plannedAttempts, attempt | Positive integers, attempts exactly `1..plannedAttempts` |
| outcome | `passed`, `failed`, `timeout`, `skipped`, `cancelled` |
| startedUs | Monotonic time read immediately before Load; for unattempted skipped rows, time the skip was recorded |
| firstPresentedUs | Legacy plan field name: **event receipt time**, not hardware presentation time; null if absent |
| firstFrameUs | Difference between the two clock observations; null if absent |

Identity labels allow only 1–128 ASCII letters/digits/dot/underscore/hyphen,
starting with a letter/digit. Never put addresses, tokens, filenames containing
usernames, response bodies or native exceptions in them. A hash documents
identity, not permission or correctness.

Baseline inputs require physical devices, profile/release, known power/thermal,
and controlled cache state. This validation is necessary but **not sufficient**
for a proper baseline: presentation semantics, correct content/audio, repeat
counts, target metrics and the measurement protocol must also be frozen. The
current integration runner deliberately only emits `purpose=smoke`.

Successful latency statistics use the usual median and nearest-rank p95. Failed,
timeout, skipped and cancelled trials remain in `attempts` and `nonPassRate`.
All unsuccessful runs have null latency statistics; missing observations never
become zero. There is no automatic pass/fail SLO or improvement percentage.

## Real playback smoke

Use `integration_test/playback_benchmark_test.dart` from the example directory.
Supply a JSON file with one Dart define named `YL_BENCHMARK_CONTEXT`; its value
is a JSON-encoded object containing all condition fields above, omitting only
`attempt`, `outcome`, `startedUs`, `firstPresentedUs`, and `firstFrameUs`.

Prepare that object from the actual checkout and device before running, retaining
the identity maps and command. Use case `local-avc-aac-mkv`, media
`assets/test_media/h264_aac.mkv`, `networkProfile=local-file`,
`cacheState=os-cache-uncontrolled`, and `purpose=smoke`. This runner supports
1–100 trials; choose counts before collection. It does not establish cold cache,
power, thermal state, screen visibility, or physical audio output.

```sh
# YL_BENCHMARK_DEFINES: absolute path to the prepared Dart-defines JSON.
# YL_BENCHMARK_LOG: destination evidence log, outside tracked source.
python3 ../../../tool/run_with_display_awake.py flutter test \
  integration_test/playback_benchmark_test.dart -d macos --no-pub \
  --dart-define-from-file="$YL_BENCHMARK_DEFINES" > "$YL_BENCHMARK_LOG" 2>&1
```

For iOS/Android select a verified device and use its actual platform/architecture
metadata. Device-specific results are not implied by the macOS smoke. The log
contains a `YL_BENCHMARK_OBSERVATION=` payload immediately after measurement,
before cleanup, and one final `YL_BENCHMARK_ROW=` payload per trial. Cleanup has
a 5-second deadline; on error/timeout a successful measurement becomes a failed
final row, the run fails, and remaining trials are explicitly skipped. Native
cleanup may still complete late, so the runner never starts another player after
a cleanup timeout. Extract those
payloads without filtering outcomes, then run `summarize.py` on the resulting
JSONL. Incomplete logs must fail completeness validation; do not synthesize
successful missing trials. Setup/build failures are separate run failures and
cannot become a zero-sample pass.

Native build warnings, foreground failures and test runner exit status belong
in the report even when all per-trial rows pass. Restore generated Flutter entry
configuration to `lib/main.dart` after integration tests before other builds.

## Next slices

P08-A still needs a validated visible-presentation boundary for formal first-frame
claims and the JS/license phase observations. P08-B will collect controlled,
correct-content baselines and freeze numeric targets, then expand to seek,
channel changes, buffering, synchronization, CPU/RSS/GPU/thermal and endurance.
No target values are invented by these tools.
