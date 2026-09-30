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
