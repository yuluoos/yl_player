# Presentation boundary and profile measurement protocol v1

Status: instrumentation protocol; no presentation latency baseline or numeric
performance target is admitted. This extends P08 Task 1/2 without changing public
player APIs, deployment targets, decoding or playback policy.

## What can currently be observed

| Observation | Actual boundary | Eligible for first-presented latency? |
|---|---|---|
| Public FirstFrame event receipt | Dart receives a session-correlated publication event after Load starts | No |
| AVPlayer texture publish | Pixel buffer handed to the texture output before the event | No compositor acknowledgement |
| Managed sample-buffer enqueue | Frame submitted with DisplayImmediately; enqueue completion is not display completion | No |
| Paused displayedPixelBuffer | System renderer returns its paused image, with content checks | No; requires deliberate pause |
| Video performance totalNumberOfFrames | Count includes frames that would have displayed had none been dropped | No per-frame first-display timestamp |

Audited sources: `YlAvPlayerBackend.displayLinkTick`,
`YlManagedPlaybackSession.didPublishFirstPresentationFrame`, and
`YlSampleBufferVideoRenderer.enqueue` in the Apple implementation. The current
SDK documents that pixel readback returns nil at nonzero rate. Its performance
metrics are cumulative, not a session-correlated first-presentation callback.
See Apple's [pixel readback API](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/displayedpixelbuffer())
and [frame count API](https://developer.apple.com/documentation/avfoundation/avvideoperformancemetrics/totalnumberofframes).
This audit does not prove no other platform measurement technique could work.

## Frozen profile smoke protocol

Before launch, save source/dependency/native-artifact/media hash maps, their
canonical sorted JSON hashes, HEAD, device/OS/architecture, command and run ID.
Source hashes include the integration test, support code and build configuration;
generated caches and collected output are excluded. Check identities again after
collection. A mismatch requires a new run identity, never a rewritten old result.

- Platform: available physical macOS host; record actual model, OS and architecture.
- Build: Flutter `--profile`, checked against the runner's `kProfileMode`.
- Input: owned bundled `assets/test_media/h264_aac.mkv`, copied before timing;
  local-file network profile; exact media hash in the context.
- Count: three predeclared attempts, no warm-up exclusion. Each owns a fresh player;
  all attempts remain in the denominator, including explicit failures/skips.
- Cache: `os-cache-uncontrolled`. Neither first trial nor fresh controller proves
  cold OS/media caches. Do not mix these samples with controlled/warm groups.
- Power and thermal: `unknown` unless measured for this run. Output `unverified`;
  foreground/window visibility and physical audio are not inferred from events.
- Start: one Dart monotonic clock immediately before public Load; end: first
  correlated public event received in the same clock. Never subtract native epochs.
- Checks: session matches, no failure, video geometry/audio track discovery and
  timeline progress past 500 ms. Track discovery does not prove audible output.
- Cleanup: existing bounded reporting helper retains the observation before
  disposal; a cleanup failure cannot pass, and later attempts are skipped.
- Run timeout: 600 seconds, owned process group only. A timeout/build failure or
  missing final row stays incomplete evidence; no partial successful summary.
- Reporting: `purpose=smoke`, exact event-receipt measurement label; success only
  verifies profile instrumentation and short playback. Do not compare with debug
  as an optimization percentage or use the statistics as a latency SLO.

Run with context `buildMode=profile` from the example directory:

```sh
FLUTTER_XCODE_ARCHS=arm64 flutter drive -d macos --profile --no-pub \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/playback_benchmark_test.dart \
  --dart-define-from-file=/absolute/path/to/defines.json
```

This command is frozen for the available Apple Silicon host only. The local
`lipo -verify_arch arm64 x86_64` fails while each single-architecture check
succeeds; `FLUTTER_XCODE_ARCHS=arm64` is passed through the Flutter-supported
Xcode build-setting environment prefix. Record this override with the command.
It does not verify Intel/universal builds or change the project defaults.

The installed `flutter test` command does not accept `--profile`; use the existing
`integrationDriver()` entry point. Preserve command-start failures as incomplete
run evidence even when no playback attempt starts.
Release requires a separate predeclared run and source/build identity; it is not
implied by profile compilation or a unit test accepting a release label.

## Future formal baseline admission

The current schema rejects `purpose=baseline` unconditionally. Implement a
separately reviewed observation boundary/schema before permitting formal latency
admission. It must identify the current session and relevant frame, start before
Load/seek, account for observation latency and clock calibration, reject stale
output, and distinguish presentation from ready/decode/enqueue. Physical screen
scanout may require an external optical measurement and synchronization protocol;
a polling callback is not automatically equivalent.

Before baseline collection, also qualify correct picture/audio for the same
route/media/output, fix physical device/OS/build, power and thermal preconditions,
network/cache preparation, warm-up/repetition/soak durations, allowed failures and
handling of condition changes. Record failures and interrupted attempts; restart
under a new identity after condition changes. Freeze numeric optimization targets
only after eligible measurements. The durations/targets for that future protocol
remain unset, not zero and not borrowed from this three-attempt smoke.

Next executable work after this smoke: select and validate a session-correlated
presentation observation technique (or explicitly adopt a separately named
publication-latency metric), then freeze the corresponding controlled protocol.
Missing physical output verification blocks only its baseline rows; other
functional plan work can continue. P08 Task 1/2 remain incomplete.

## Resource attribution control (2026-09-30)

Before attributing the ten-cycle footprint increase, run one fresh profile
`--profile-control` and one fresh `--profile-cycles` process, in that order, with
identical source fingerprints, host architecture, fixture and sampler source. Each has
ten cycles, 250 ms sampling, two seconds idle and two seconds after cleanup.
Control keeps fixture copying, empty MaterialApp mounting, sampling/logging and
independent cleanup, but never creates/loads a player; its `playing` phase is a
two-second wall-clock wait. Playback retains its existing media-position >= 2 s
condition. Opening/playing durations and resource allocation therefore need not
match exactly. No VM polling, forced GC, cache clearing or warm-up is added to
this pair. OS cache remains uncontrolled; no numeric threshold is frozen.

Resource trial schema 2 explicitly carries `workload=playback|harness-only`.
Legacy schema 1 means playback; mixed versions/workloads are rejected. Controls
are profile-only and engine/decoder remain unknown. A passed control means only
that the harness completed; it is never successful playback evidence. Retain
all failures/skips/unknown conditions and the actual last disposed sample.
Compare endpoint trends as exploratory observations, not a subtraction yielding
player-owned bytes or a leak verdict. The Dart/native/OS ledgers differ, and
public dispose acknowledgement is not proof of complete native deallocation.

The sampler is rebuilt in each fresh output directory. Its Mach-O install name
contains that directory, so full dylib hashes may differ even for the paired
runs. Keep both hashes; verify the paired section contents and size independently
before treating their sampling code as equivalent. This does not make two app
processes identical or control the OS cache.

## Memory category diagnostic (2026-10-07)

`run_memory_categories.py harness-only|playback NEW_DIRECTORY FLUTTER` reuses the
profile ten-cycle resource run. In separate fresh processes, run harness-only
then playback. After receiving final trial rows 2, 5 and 8, verify the run/schema,
workload and PID, and require `ps` to identify the exact Profile example executable
before invoking `/usr/bin/vmmap -summary PID` (10 s deadline, no process-name scan).
Keep raw reports, hashes, host start/end timestamps, failed/unobserved probes and
all playback trials. Snapshots may overlap the next cycle and vmmap may pause or
perturb the process; these are diagnostics, not simultaneous disposed endpoints
or baseline observations. No forced GC, allocator-pressure call, MallocStackLogging
or product changes. Do not subtract host timestamps from native raw clock values.

Parse only the observed report version 7 and exact category column order. Preserve
reported rounded units and category labels; unknown versions, malformed rows,
wrong PIDs, duplicate categories or incomplete tables are failures. Missing
categories stay absent, not fabricated zero; retain failures and raw reports.
Virtual, resident, dirty, swapped and process physical footprint are distinct
ledgers; their totals need not reconcile. `Malloc Large (empty)` is a system
category, not an object count, ownership proof or no-leak verdict. This protocol
has no frozen performance threshold. Allocation stacks and native object lifetime
measurements require a separate, explicitly recorded diagnostic protocol.

## Address history and object-lifetime windows (2026-10-07)

For the address experiment, run a separate ten-cycle harness-only process with
full, noncompacted malloc stack history. Build normally, then launch the prebuilt
app through the existing driver with process-local MallocStackLogging=full and
MallocStackLoggingNoCompact=1. After cycle 5, verify the exact owned PID/executable,
capture wide noncoalesced vmmap regions, and query malloc_history only for up to
two 7–9 MiB Malloc Large (empty) regions, at their start and +16/+32 KiB interior
addresses. Preserve missing regions and failed queries; interior queries are
metadata history lookups, not object contents. This is a diagnostic experiment,
not a new allocator setting or performance comparison.

run_lifetime_probes.py NEW_DIRECTORY FLUTTER separately enables example-only
20-second checkpoints: cycle 1 after media position reaches 2 s but before
disposal (live), and cycles 2/8 after disposal and the ordinary 2 s observation.
Capture heap --noContent once per checkpoint with a 10 s deadline after verifying
the exact owned executable. The app delays before the next operation; it does
not ask the allocator to collect. The live fixture may end during its checkpoint
but the controller/session remain owned. No MallocStackLogging is enabled here.

Both marker and observer timestamps use macOS CLOCK_MONOTONIC_RAW in microseconds.
Qualify only matching begin/end run/PID/trial/phase identities with the complete
command interval inside that window; missing markers, tool failures or out-of-window
captures cannot prove post-disposal state. Keep raw heap output and all statuses.
A positive live capture is needed before interpreting a missing class later:
the tool may not recognize every Swift/native allocation. No global no-leak
verdict, byte reclamation guarantee, GPU completeness or performance admission.
The extra wait/tool overhead changes the protocol; do not compare these deltas
to the original ten-cycle measurements.
