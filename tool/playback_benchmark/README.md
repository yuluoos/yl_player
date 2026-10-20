# Playback measurements

## macOS paused display-layer readback

From `packages/yl_player/example`, run:

```sh
flutter test integration_test/display_readback_test.dart -d macos --no-pub \
  --dart-define=YL_DISPLAY_RUN_ID=display-owned-001
# Metadata-only BT.601 matrix / BT.709 primaries+transfer control:
flutter test integration_test/display_readback_test.dart -d macos --no-pub \
  --dart-define=YL_DISPLAY_RUN_ID=display-owned-601 --dart-define=YL_DISPLAY_CASE=bt601
# Negative qualification case, not a playback/color-accuracy pass:
flutter test integration_test/display_readback_test.dart -d macos --no-pub \
  --dart-define=YL_DISPLAY_RUN_ID=display-unqualified --dart-define=YL_DISPLAY_CASE=untagged
flutter test --no-pub test/display_markers_test.dart
```

Use a fresh nonsecret run ID, retain the complete log (including failed/skipped
rows), and record the checkout/source/config/dependency/media hashes before a
run, as in `macos-display-readback-observations.json`. This explicit Debug-only
example channel uses macOS 14.4+ `AVSampleBufferVideoRenderer.displayedPixelBuffer()`;
unsupported systems fail the probe without changing package deployment targets.
It traverses only the example window, requires exactly one display layer, and
does not capture the screen or protected content. The channel is absent from ordinary profile/release builds. The continuous
counter test below explicitly opts its example profile build into the probe;
this does not change the production player package.

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

Schema 2 adds `caseId` and per-sample `colorMetadata` (matrix, primaries,
transfer and Core Image resolved `rgbColorSpace`), using fixed labels rather
than arbitrary native descriptions. The pure-RGB reference is qualified only
for BT.601/BT.709 matrices, BT.709 transfer, resolved Core Media 709 RGB space,
and BT.709 or renderer-normalized unspecified primaries. An unspecified
primaries attachment alone does not qualify or disqualify the image: the tested
renderer returns it even for fully tagged positive controls. Missing/other
resolved spaces (including an unnamed space) and explicit conflicting primaries
cannot pass even if the RGB happens to match. Such readbacks remain in raw
observations and yield `reference-unqualified`; remaining trials are skipped.
The `untagged` negative suite succeeds only when this exact outcome sequence is
observed. Its test-runner exit 0 is **not** an original-media color-accuracy pass.
Other color spaces require their own reference and are not rejected by the
production player through this test-only rule.

`generate_color_control.py` creates `benchmark_601.mkv` by changing SPS/container
color metadata only. It verifies all 96 decoded video and 189 audio frame hashes
against the untouched original; no image re-encoding is involved. This control
distinguishes reference interpretation from damaged decoded samples. The old
untagged red observation had correct YUV and a BT.601 matrix, but unspecified
primaries; an assumed pure-sRGB reference did not justify a decoder/matrix fix.
See `macos-color-reference-observations.json` for separately retained positive
controls and the unqualified original. No production color-default override,
tolerance relaxation, first-frame latency or physical-color claim follows.

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
| purpose | `smoke`; `baseline` is rejected for the current event-receipt schema |
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

The current schema accepts **smoke only**, including profile/release smoke.
`purpose=baseline` is rejected even on physical hardware with known power,
nominal thermal state and controlled caches: none of these supply the missing
presentation acknowledgement. Relabeling `measurement` is also rejected by the
fixed allowlist. The Dart runner already enforces smoke-only input. Historical
summaries are preserved as historical evidence, not retroactively admitted.
See [measurement-protocol.md](measurement-protocol.md) for the frozen profile
smoke protocol, observed API boundaries and requirements for a future baseline.

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


## Continuous renderer counters (macOS 14.4+)

`video_performance_test.dart` observes the existing display layer during playback
without pause or seek. It loads the owned `benchmark_sdr.mkv` once per attempt,
waits for the public first-frame event, polls at a nominal 250 ms cadence until
media position reaches 3 seconds, and requires increasing counters from at least
two valid snapshots. Three attempts are declared before launch; 10-second polling
and 80-snapshot limits apply. No-layer/no-metrics samples remain in the record.
Native callbacks have a two-second deadline; late callbacks are ignored. The Dart
channel has a three-second deadline. Failure/timeout/unavailable or counter reset
aborts later attempts as skipped. Four cleanup steps remain independently bounded.

For the available Apple Silicon host, from the example directory:

```sh
FLUTTER_XCODE_ARCHS=arm64 \
FLUTTER_XCODE_SWIFT_ACTIVE_COMPILATION_CONDITIONS=YL_VIDEO_PERFORMANCE_PROBE \
flutter drive -d macos --profile --no-pub \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/video_performance_test.dart \
  --dart-define=YL_VIDEO_METRICS_RUN_ID=owned-video-metrics-001
```

The Swift flag enables only the example's read-only probe in this explicit profile
build. Ordinary profile/release builds and the production package are unchanged.
This adds observation overhead, so it is not comparable with the prior profile
run lacking this probe. Use fresh run/source/media/dependency/command identities;
retain complete logs and all rows, including failed and skipped attempts.

Schema 1 (`continuous-renderer-counters`) uses `YL_VIDEO_METRICS_ROW`, separate
from the first-frame summarizer. Each sample has status, layerCount, totalFrames,
droppedFrames, corruptedFrames, totalFrameDelaySeconds and Dart receivedUs. Missing
values are null. Samples are immutable; negative/nonfinite values, unknown fields,
clock reversal and counter resets cannot produce a successful delta. Only
schema-valid snapshots with an accepted receipt time enter the raw sample list;
malformed payloads are not echoed, and the failed trial still remains. Valid
reset/unavailable snapshots are retained before rejection. Delta spans
the first and last observed snapshots, not the whole media duration or wall time
of the renderer's internal sampling. It does not subtract clocks across APIs.

These are raw system renderer counters. `totalFrames` includes frames that would
have displayed without drops, not proof each frame displayed; do not call
`totalFrames - droppedFrames` physical presentation. Accumulated frame delay is
not user-visible stall duration or AV sync error, particularly for this player's
DisplayImmediately sample path. No ratio, threshold, first-frame timestamp or
physical-output claim is inferred. `firstPresentedUs` stays null and both
performanceBaseline/physicalOutputVerified remain false even on passing trials.
The earlier pixel-reference checks are separate evidence, not profile pixel or
audio validation. Profile counters alone cannot close full P08 Task 1/2.


## Profile load/dispose resource cycles

```sh
python3 -B tool/playback_benchmark/run_resources.py --profile-cycles \
  /absolute/path/to/fresh-result-directory /absolute/path/to/flutter
```

The optional mode predeclares **10** sequential fresh-player trials in profile,
using `flutter drive` and the host's single architecture. It retains the existing
local AVC/AAC resource fixture and 250 ms sampling cadence. Each trial waits 2 s
idle, plays until media position reaches 2 s, independently attempts disposal,
view removal and temporary-media deletion (5 s each), then observes 2 s after
acknowledged cleanup. This is approximately one minute of repeated lifecycle
work, not a long-duration soak. Default invocation remains a three-trial Debug
smoke. No warm-up trial is removed; caches remain OS-uncontrolled.

A creation timeout remains unconfirmed even when no instance was handed back;
the existing late-owner helper still releases it. Known observations are emitted
before cleanup as `YL_RESOURCE_OBSERVATION`. Final `YL_RESOURCE_SERIES` keeps the
original schema, including failed/timeout/skipped outcomes, and aborts further
playback after failure. The resource sampler observes this process, including
the test harness and observer overhead. It cannot identify decoder-only usage.

The runner stores exact commands, phase durations, planned count, source,
media/dependency/native artifact and sampler identities. `disposedMemory` retains
one endpoint per attempt. It uses the **actual last disposed sample**, never an
earlier good value if the last reading is missing. A first-to-last endpoint delta
is produced only for a complete run with at least two passed attempts, at least
two disposed samples spanning 1 s per attempt, ordered nonoverlapping trial
clocks, and one known power/thermal condition across every collected sample.
Malformed/incomplete run identities or overlapping clocks are rejected; the runner
retains raw observations and records classification failure. For structurally
valid complete runs with failed/skipped attempts, missing/short disposed windows,
or unknown/mixed conditions, delta and elapsed window are null while endpoints
and outcomes remain.
The requested 2 s settling period is not proof that all allocations have settled.

RSS and physical footprint are separate byte counters. Positive growth can
include caches/allocator retention; negative growth does not prove leak freedom.
`leakVerdict` stays null and `performanceBaseline`/`budgetAdmission` stay false.
No tolerance, software-decoder budget, leak verdict or long-run release gate is
inferred from ten short cycles. Layer absence, physical picture/audio and GPU or
media-ledger ownership are not measured by this resource-only run.

## Extended lifecycle endurance (100 profile cycles)

```sh
python3 -B tool/playback_benchmark/run_resources.py --profile-endurance \
  /absolute/path/to/fresh-result-directory /absolute/path/to/flutter
```

This freezes the protocol and identities in `protocol.json` before launch. It
extends the existing playback cycle to 100 attempts and requires at least 600 s
of resource observation; the integration and command deadlines are 900/1200 s.
It cannot be combined with harness-only control or lifetime diagnostic windows.
The existing 256-sample bound remains per cycle, avoiding an unbounded in-app
sample list. All outcomes remain in the planned denominator; a failure stops
further playback, and timeout/crash logs stay available even if final rows are
incomplete. `endurance.protocolCompleted` is a protocol-completion gate, not a
memory-growth, continuous-playback, picture/audio or no-leak verdict. The
four-second fixture is repeatedly opened and disposed. See
[the predeclared protocol](measurement-protocol.md#extended-load-dispose-observation-2026-10-07-fixed-before-execution)
for windows, failure handling and unverified workloads.

## Long-cycle native lifetime and memory-category attribution

```sh
python3 -B tool/playback_benchmark/run_lifetime_probes.py --long-cycles \
  /absolute/path/to/fresh-result-directory /absolute/path/to/flutter
```

This separate 100-cycle diagnostic waits 30 s at live cycle 1 and disposed cycles
10/50/100. Each window collects heap metadata (`--noContent`) and a vmmap summary
with independent 10 s limits, exact owned-process guards, raw hashes and native
clock brackets. The final report retains all eight planned observations,
including failures/unobserved probes. Schema-2 long-cycle markers cannot mix with
legacy short-cycle markers. Existing no-flag invocation retains the three-window
heap-only diagnostic. The added pauses/probes change the workload; numeric deltas
cannot be interpreted as improvement over the uninstrumented endurance run.
See the frozen protocol for phase boundaries and ownership/absence limitations.

Add `--memory-mapping` together with `--long-cycles` to retain detailed Untagged
address ranges and collect metadata-only Dart isolate-group heap usage alongside
heap/vmmap in the same four windows. This records 12 planned probes. The loopback
VM PID/group set is verified before and after memory calls; unsupported responses
remain failures. Each Dart observer runs in its own bounded process, follows no
redirects/proxies and does not request GC. Exact virtual address sizes and rounded
resident usage remain separate; neither group counters nor matching addresses
prove ownership. See the predeclared Dart heap/address mapping protocol.

## System isolate groups and bounded address history

```sh
python3 -B tool/playback_benchmark/run_address_history.py \
  /private/tmp/yl-system-address-new /absolute/path/to/flutter
```

This diagnostic freezes `protocol.json` before launch and uses ten profile
load/dispose cycles with three 20-second windows (live 1, disposed 2 and 8).
It builds normally, then launches the owned application with full malloc stack
logging and non-compacted history. The environment affects only the launched
process tree. It does not change production code, entitlements or system settings.

Each window captures detailed vmmap, application **and system** isolate-group
memory, then three bounded malloc_history queries (2 seconds each). At live 1,
the largest Untagged `rw-/rwx` region of at least 8 MiB is selected, with lowest
address as the tie-break. Queries reuse its base, base+16 KiB and base+32 KiB;
selection is not changed after observing later dirty-page growth. Reused query
addresses do not prove allocation continuity. Untagged reserved address space
is a separate category. `Performance Tool Data` retains its explicit exclusion
from the vmmap TOTAL rather than being silently counted as application memory.

Dart queries preserve the earlier default application-group-only mode; the
`memory_mapping.py --include-system` option requires both group lists and
rejects duplicate IDs across them. Unsupported/missing values fail the probe,
never become zero. Before/after VM identity checks and durable RPC journals also
apply to system groups; no GC is requested. Samples are sequential, not atomic.

All 15 planned probes remain in `history-probes.json`, including missing or
failed probes. A completed capture qualifies only inside its own paired native
clock window. A history command's `captured` status means its output was retained;
it does not assert allocation/free matching, ownership or absence of leaks.
Allocation claims require inspection of exact ranges and full stacks in the raw
files. Stack logging changes process memory and timing; this run is not a
performance baseline and must not be numerically compared as an optimization
against uninstrumented runs. Incomplete newline-terminated checkpoint JSON
fails closed; an unterminated trailing line is retried after the writer finishes.

## Runtime Profiler on/off comparison

```sh
python3 -B tool/playback_benchmark/run_profiler_comparison.py \
  /private/tmp/yl-profiler-pair-new /absolute/path/to/flutter
```

This predeclared short protocol runs separate `on` then `off` processes, each
with ten profile playback cycles and the same live-1/disposed-2/disposed-8 windows.
At live 1, **after the first player load**, the collector checks its owned
executable/PID and calls `getVM`, `getFlagList`, `setFlag(profiler, true/false)`,
`getFlagList`, `getVM`. Both arms execute the same RPC sequence. Later checkpoints
read the flag without changing it. Each verified flag probe precedes detailed
vmmap and application/system group memory. The collector rejects inherited
`MallocStackLogging*` environment variables. No GC is requested.

The HTTP helper remains read-only by default. Its explicit profiler-control
option permits only the exact `setFlag` name `profiler` with string `true` or
`false`; arbitrary flags, values and extra parameters are rejected before a
request. It uses the existing loopback-only endpoint validation, response limits,
process deadlines and durable raw journals. Actual readback is required; a
successful setter alone is insufficient. PID and validated application/system
group IDs must match before/after and across windows. Raw VM `startTime` values
are retained but are not an equality gate: this host returned a 1 ms variation
within one unchanged VM.

All nine observations per arm retain their planned identities; failures and
unobserved probes cannot qualify. Both successful arms must match source,
dependency/native artifact/media/device/architecture/build/protocol identities,
and have distinct PIDs. Fresh sampler libraries have path-dependent install
names, so their binary hashes can differ; their source is covered by the shared
source hash and each binary hash is retained. Application binary fingerprints
are recorded separately before the next build.

This checks a **runtime** switch, not startup without Profiler. Disabling sampling
may retain the sample buffer. Fixed arm order, one pair, uncontrolled OS caches
and sequential metadata probes prevent a performance-benefit or release-baseline
claim. A similarly sized mapped region is descriptive evidence, not proof of
cross-process allocation identity. See `macos-profiler-control-observations.json`
and the P08 report for retained incomplete and final observations.

## Profiler-off hundred-cycle resource and lifetime observations

```sh
python3 -B tool/playback_benchmark/run_profiler_comparison.py --long-off \
  /private/tmp/yl-profiler-off-long-new /absolute/path/to/flutter
```

This independent mode requires 100 profile load/dispose cycles and at least 600
seconds between the first and last resource points. It reuses the existing
schema-2 long windows: live 1 and disposed 10/50/100, each 30 seconds. The test and
command deadlines remain 900 and 1200 seconds. The root protocol and resource
collector's identity/protocol file are both frozen before the measured launch.

There are 16 planned probes. Each window first verifies the runtime Profiler
state, then captures `heap --noContent`, detailed vmmap, and application/system
Dart group memory. Only live 1 requests `setFlag(profiler,false)`; the three
subsequent checks are read-only. Failed/unverified control prevents later probes
from being treated as a valid off-state observation. Complete qualification
requires every probe to fit its own paired native-clock window, all 100 playback
trials to pass, the minimum resource span to pass, and consistent PID/group IDs.
Missing or partial observations retain their planned identities.

This mode rejects the `on` arm and incompatible resource modes. The earlier
short on/off mode is unchanged. No MallocStackLogging or GC is enabled, and there
is no production/Dart/SDK change. As before, Profiler is stopped after the first
player load; state is checked at four windows, not monitored continuously.
Load/dispose cycles and checkpoint waits are not continuous film playback.
Missing heap class rows mean not listed, not zero allocations or proof of free.
The independent run is not a matched hundred-cycle on/off experiment; do not
subtract earlier runs to claim an optimization or global absence of leaks.

### Bounded non-object allocation stack attribution

```sh
python3 -B tool/playback_benchmark/run_allocation_stacks.py NEW_DIRECTORY /path/to/flutter
```

Runs an independent ten-cycle profile diagnostic with MallocStackLogging=full
and MallocStackLoggingNoCompact=1 using the existing prebuild/launch wrapper.
At live 1 the runtime profiler is set off and read back; disposed 2/8 only
observe its state. Each existing 20-second window captures control, heap
`--noContent`, then `malloc_history -callTree -noContent -invert -ignoreThreads
.*`, with an eight-second tree timeout. Selection covers the entire live allocation
tree because MSL assigns derived names to non-objects. Empty graphs are rejected;
no address sampling or object-content reads are used.
All nine planned observers remain in the result, including missing/failed ones;
each complete capture must fit its native-clock window and owned process.

A qualified capture is not a proof of stack coverage or ownership. Full raw
call trees must be inspected for unsymbolicated/no-stack allocations and
attribution scope. Stack logging perturbs resources; do not compare these
numbers directly with the prior uninstrumented hundred-cycle run as a
performance improvement or claim all residual growth is explained. No forced GC,
production changes, startup-disabled profiling, or global leak verdict.

### Timeline stream control comparison

```sh
python3 -B tool/playback_benchmark/run_timeline_comparison.py NEW_DIRECTORY /path/to/flutter
```

Freezes an on/off pair before launch. Both independent ten-cycle profile arms
use MallocStackLogging=full/NoCompact and disable the sampling profiler after
first load. At live 1, `setVMTimelineFlags` selects Dart/Embedder/GC/Microtask
or an empty list; `getVMTimelineFlags` verifies recorder, supported streams and
actual recorded streams. Disposed 2/8 are read-only, including profiler checks.
No `clearVMTimeline`, forced GC, SDK edit or startup-disabled claim is involved.

Each 20-second window collects control, full `heap --noContent` type rows and
detailed vmmap, with ten-second process bounds and exact owned PID/group/window
gates. All nine planned probes per arm remain, including failed/missing captures.
The root pair and each arm protocol are saved before their respective launches;
short resource metadata is saved in results. The resource conditions and initial
Timeline state must match across distinct PIDs. Fixed order, uncontrolled OS
cache and MSL overhead limit interpretation: compare identified allocation
sources, not product performance percentages or global leak status.

### Long profiler and Timeline disabled observation

```sh
python3 -B tool/playback_benchmark/run_timeline_comparison.py --long-off NEW_DIRECTORY /path/to/flutter
```

This independent profile run rejects inherited MallocStackLogging settings and
uses the existing 100-cycle workload, at least 600 seconds of resource sampling,
and four 30-second windows (live 1; disposed 10/50/100). Both the root diagnostic
and resource protocols are saved before launching their measured process.
At live 1, set profiler false and Timeline recordedStreams empty, then read back;
later windows only observe state. Each window captures control, heap --noContent,
detailed vmmap and application/system isolate-group memory, in that order.
All 16 planned probes remain in the result. State, owned PID/group, native clock,
full workload and minimum-duration gates must pass before completion.

No MSL, clearVMTimeline, forced GC or production changes are involved. This is
load/dispose endurance, not continuous movie playback. The intervention occurs
after first load; initial recorder allocations may remain. This single run is
not a matched on/off performance baseline and cannot establish global absence
of leaks, long-term plateau or cross-device results.

### Single-session continuous synthetic AVC observation

```sh
python3 -B tool/playback_benchmark/run_continuous.py NEW_DIRECTORY /path/to/flutter
```

`continuous-avc-v2` freezes one create/load/play and a 1,200-second observation
starting after the public first-frame event and media position >=2 seconds.
There are no pause, seek, loop or reload calls. The checked-in owned 1,260-second
320×180/24 fps AVC + silent AAC fixture is generated with
`generate_continuous_fixture.py` (fresh destination only, host FFmpeg required).
The source, fixture, dependency/native artifact and sampler hashes, device,
profile mode and complete protocol are saved before launching the workload.

Each five-second record includes the same session ID, public playback state,
position, selected audio/video presence and process resources. Any observed
non-playing state or player failure is sticky, including between sample ticks.
Rows are printed individually; interrupted/malformed runs retain their raw log.
The classifier requires >=1,200 seconds, no gap above 7.5 seconds, interval media
progress between 90–110% of raw-clock elapsed time and <=5 seconds cumulative
drift. These are instrumentation/continuity gates, not product performance SLOs.
Resource schema 3 names the distinct cadence and single attempt; the existing
256-sample limit and schema 1/2 semantics remain. After disposal/unmount, two
resource samples span at least two seconds; cleanup must be acknowledged.
The test deadline is 22 minutes and command deadline is 25 minutes. A temporary
`caffeinate -d -i -u -t 1500` assertion is owned by the command; it does not
change power settings or guarantee that macOS foregrounds the test window.

This run leaves Flutter's profile-mode profiler/Timeline configuration at its
launch defaults; it performs no runtime state control and does not attest those
flags. MallocStackLogging variables are rejected. No forced GC occurs. CPU is
actual-time weighted; RSS/footprint, power and thermal are observations only.
Do not compare resource amounts directly with the separately controlled
profiler/Timeline-off cycle runs, claim a leak/plateau/optimization ratio, or
infer physical video presentation, audible output or AV sync from public state.
The low-resolution synthetic fixture supplies bounded duration coverage, not
full-feature-film, high-bitrate, HDR, DRM, background or memory-pressure coverage.

### Native audio callback ownership probe

`python3 -B tool/playback_benchmark/run_audio_callback_roots.py /private/tmp/NEW_DIRECTORY`
compiles a standalone Swift AVAudioEngine graph and schedules 200 silent,
noninterleaved stereo 48 kHz buffers of 1,024 frames with `.dataPlayedBack`.
The fresh-directory runner freezes source/binary hashes and its protocol before
launch, enables full malloc stack logging, then holds four checkpoints:
configured, all callbacks delivered, stop/reset, and stop/disconnect/detach.
Each checkpoint captures heap and dispatch-source allocation stacks, plus the
first still-live callback marker's reverse reference tree and allocation history
when one exists. Missing markers are explicit inapplicable slots, never fake
successful reference traces. Sixteen slots remain in the result after failure;
owned PID/executable checks and eight-second observer deadlines bound inspection.

The runner may require permission for local process inspection. It never resets
production playback. This graph mirrors the native output path, but does not run
Flutter, the decoder, the managed buffer ledger, or the production renderer.
The engine/player remain alive after detach. Results diagnose the current
machine only; they do not certify audio timing, audible output, long playback,
performance, or the origin of every byte in previous process measurements.

### Audio callback mode comparison

`python3 -B tool/playback_benchmark/run_audio_callback_modes.py /private/tmp/NEW_DIRECTORY`
compiles a standalone graph with the checked-in production completion group.
It runs consumed/rendered/playedBack in that order, first at steady rate 1, then
with pause at 1 second, resume at 1.5, rate 2 at 2, and rate 1 at 3 seconds.
Each independent process schedules 200 silent 1,024-frame stereo 48 kHz buffers.
For eight seconds it journals callback types/timestamps and samples player time,
rate, play state, and reported downstream/output latency on the main thread.
Callback threads never call back into player/engine APIs. The sample target is
10 ms, with recorded actual intervals and a 250 ms admission gap/action-start
tolerance; this is diagnostic coverage, not a playback performance SLO.

Heap and dispatch-source allocation stacks are collected only at configured,
post-observation, and disposed handshakes (36 planned probes total). Full malloc
stack logging and sampling still perturb the process. Source/binary identities,
protocol, raw observations, failures, and missing probe slots are retained.
The analyzer keeps both neighboring clock reads, excludes transport crossings or
missing clocks, and never treats interpolation or reported latency as physical
audibility. These fixed-order short runs do not establish CPU/latency improvement,
route-change behavior, general consumed/rendered equivalence, or a safe direct
replacement of playedBack in the production renderer.

## Offline joint release inventory (2026-10-16)

P08-D now has a [source-bound coverage checker](../release_readiness/README.md)
for all CAP/ERR/REG platform groups and performance/consumer/CI gates. Its normal
exit 0 validates the inventory, not release readiness; `--require-ready` returns
1 while any requirement remains open. Historical partial reports cannot become
full acceptance by relabeling their status. This tool does not run devices or
freeze numerical performance targets.

## P08 multi-metric engineering contract

The original JSONL `summarize.py` remains smoke-only. `performance_gate.py`
accepts one complete run object with `conditions`, `qualification`, explicit
`metrics` and ordered `trials`. The examples in `test_performance_gate.py` are
synthetic unit-test values, **not product thresholds**.

Each metric defines a fixed unit and observation boundary. Public event receipt,
command acknowledgement and phase-clock spans can be measured without claiming
physical output. Output/seek-stability/synchronization metrics require a physical
device plus a calibration hash; source-to-output latency also needs a trusted
source-clock hash. Process RSS/CPU, GPU observations, script heap and media ledger
stay separate. Nonnegative absolute errors or observations are supported; signed
resource changes remain in the existing resource-series tools. Unknown values are
null. No inferred zero CPU/GPU/thermal/synchronization is emitted.

All attempts, including warmups, remain in the outcome counts. Warmups are
excluded only from latency statistics; warmup failures and failed/unknown cleanup
still count against the failure budget. A failed attempt's partial measurements
are retained in the run but excluded from successful statistics. Every selected
metric must have the declared minimum successful samples. Median and nearest-rank
p95 include `n`; a small `n` does not establish a statistically strong SLO.

```sh
python3 -B tool/playback_benchmark/performance_gate.py summarize RUN.json
python3 -B tool/playback_benchmark/performance_gate.py freeze BASELINE.json POLICY.json NEW_FROZEN.json
python3 -B tool/playback_benchmark/performance_gate.py check CANDIDATE.json FROZEN.json
python3 -B tool/playback_benchmark/threshold_registry.py --require-ready
```

`freeze` requires profile/release, nominal thermal state, known power, explicit
content-verification evidence, sufficient samples and a product-supplied policy.
It writes exclusively to a new file and embeds/hashes the full baseline and policy.
Freeze it **before** making the optimization; retained commit/source identities
support review but cannot prove when a human originally created an external file.
The checker does not supply product tradeoffs or infer physical evidence from a
hash. Evidence authenticity and calibration semantics require separate review.

The policy contains `version`, `minimumSamples`, `maximumNonPasses`, and per-metric
`p50`, `p95`, `maximum`, `maxRegressionRatio` (nullable, relative to baseline p95).
Candidate conditions, method, dependencies, sample/warmup counts and comparability
must match exactly. Source/commit/native artifacts may change for the optimization.
Changed methods/cache/devices require a new baseline version. When
`baselineComparable=false`, only absolute limits apply; no improvement percentage
is printed. A zero baseline likewise never divides by zero.

`thresholds.json` is a versioned registry with explicitly pending device profiles,
not invented numeric SLOs. Each future entry references hash-bound frozen baseline,
candidate and the complete source map used by the public collector. The registry
recomputes the current source map and rejects stale comparisons. Entries are
excluded from the measured source map to avoid self-referential hashes. The
registry must be marked `frozen` and every required profile must pass before it is
ready. Pending/missing/failed/stale evidence is not a release pass.

Commands return 0 for valid summaries/freezes or passing comparisons, 1 for a
failed comparison/readiness gate, 2 for invalid input. Error messages do not echo
input, credentials or native exceptions. Full release acceptance additionally
requires the separate CAP/ERR/REG, consumer and CI inventory; use
`sh tool/check_p08.sh --require-ready` to require both gates.

## Public multi-player ownership workload

```sh
python3 -B tool/playback_benchmark/run_public_stress.py NEW_OUTPUT /absolute/path/to/flutter
```

The host collector freezes source/dependency/artifact/media identity and
`stress-protocol.json` before launching a bounded macOS profile run. All failures,
raw log prefixes and result receipts remain in the fresh output directory. It
never kills unrelated applications. The portable Flutter target
`integration_test/playback_stress_test.dart` also supports Android/iOS when given
an actual device/build context and the protocol hash via Dart defines.

Three attempts each create two controllers, load/seek/pause/resume/replace,
reject stale commands, stop the active controller, explicitly restore the peer,
observe its progress and dispose both. Apple commits intentionally deactivate
peer video leases; this exercises multi-instance ownership, **not simultaneous
independent video playback**. Muted app-managed audio avoids claiming audible or
physical synchronization. Actual observed metrics include event/command durations
and nullable native buffering/media bytes; no RSS/GPU values are synthesized.

The workload is short and does not impersonate long playback, physical background,
low-memory or thermal tests. Existing `run_resources.py --profile-endurance`,
`run_continuous.py`, lifetime/heap/Timeline tools and platform lifecycle tests
remain the corresponding execution paths. This new run's content qualification
stays false until independent evidence exists; its `run.json` cannot be frozen
into a formal output baseline merely because playback assertions passed.
