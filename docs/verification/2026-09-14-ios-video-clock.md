# iOS video freeze and catch-up: audio clock correction

## Reproduced defect

The managed playback path fed `YlMediaClock` only completed PCM timestamps.
Delayed `dataPlayedBack` callbacks therefore froze the video clock while audio
continued to render, then advanced it in a burst. A real renderer/clock/scheduler
regression with controlled output timestamps reproduced position 0 instead of
40,000 microseconds. All three initial new tests failed; the 15 existing audio
renderer tests passed.

## Change

`YlAudioRenderer` maps the player sample timeline into media time between
completion callbacks. It caps progress at scheduled PCM, reanchors on refill
independently of callback delivery, and preserves the player sample offset across
pause. Flush/reset discards the old anchor; stale completions remain rejected.
Playback rate is already reflected in player samples and is not applied twice.
Callbacks continue to release buffer accounting and provide a fallback when a
native timestamp is unavailable.

The scheduling/pause/stop semantics follow Apple's
[AVAudioPlayerNode documentation](https://developer.apple.com/documentation/avfaudio/avaudioplayernode).
The installed SDK header also documents that `playerTime(forNodeTime:)` returns
nil when the player is not playing; pause snapshots time before pausing.

## Execution evidence

- Final iOS native run: 49 passed, 0 failed, 0 skipped on iPhone 17e Simulator,
  iOS 26.5. Suites: `YlAudioRendererTests`, `YlMediaClockTests`,
  `YlFrameSchedulerTests`, `YlFallbackLifecycleTests`.
- Four new test methods cover delayed callbacks with continuous frame selection,
  PCM endpoint limits and starvation, pause/seek/reset/rate, and refills before
  callback delivery (both playing and paused). Boundary regressions were observed
  failing before their corresponding corrections.
- Result bundle: `/private/tmp/yl-ios-clock-verified.xcresult`.
- Shared-code compatibility: 10 macOS `YlMacosAudioTests` passed, 0 failed,
  0 skipped. Result bundle: `/private/tmp/yl-clock-macos-verified.xcresult`.
  Its generated test package likewise required a command-line
  `MACOSX_DEPLOYMENT_TARGET=12.0` override.
- Two existing real-MKV integration tests (sustained 3x recovery and long video
  tail) both fail at position zero with `decoder.video_decode_failed`. Restoring
  `YlAudioRenderer.swift` byte-for-byte from `HEAD` and repeating the same tests
  produces the same two failures and error code. This is not passing integration
  evidence. Logs: `/private/tmp/yl-ios-clock-probe.log` and
  `/private/tmp/yl-ios-clock-baseline.log`.
- Temporary instrumentation and baseline substitutions were removed afterward.
- Audio fixture/main-example parity and canonical iOS inventory (401) pass;
  `git diff --check` passes.

## Validation limits

This correction targets managed playback. The reporter's original video URL,
format and physical iPhone are not available, so the exact reported occurrence
has not been verified on that device.

The full source-parity gate has pre-existing discrepancies in
`YlFFmpegBridgeTests.swift`, `YlHlsManifestRewriterTests.swift`,
`YlOpenedMediaTests.swift`, and `YlVideoToolboxDecoderTests.swift`; comparing each
fixture against `HEAD` confirmed these precede this change. This change's audio
test fixture and main-example copy are kept identical. No full-matrix claim is made.

The generated Flutter test package currently declares iOS 13, while the plugin
requires iOS 15. Native test commands override `IPHONEOS_DEPLOYMENT_TARGET=15.0`.
Existing unrelated Swift Sendable warnings remain.
