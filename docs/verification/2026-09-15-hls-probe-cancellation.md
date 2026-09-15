# HLS probe cleanup must not cancel Load

## Cause and correction

The HEVC-in-MPEG-TS compatibility probe used the enclosing Load's cancellation
token. After successfully recognizing H264, `prepared.discard()` cancelled that
token while releasing the unused managed candidate. The open coordinator then
rejected the AVPlayer candidate with `network.cancelled`.

The probe now owns a separate token. Load cancellation propagates into the
probe, while probe cleanup cannot cancel Load. A selected HEVC candidate retains
its probe token with the managed session. No timeout, buffer, retry, clock,
decoder or routing policy was changed.

The earlier interpretation of the reported 7,884 ms as an eight-second startup
timeout was unconfirmed. The local H264 regression failed in about 1.4 seconds
before the fix, without a caller timeout or Stop.

## Execution

- Before the production change, the real HTTP/H264-TS host-load regression
  failed with a native Pigeon error. The test server decrypts the existing
  bundled H264 fixture; it does not replace the demuxer or playback coordinator.
  The original failure's verbose diagnostic collection stalled after XCTest
  completed and was stopped. Its test output remains under
  `/private/tmp/yl-hls-probe-red2.xcresult/Staging`.
- iOS 27.0 / iPhone 18 Pro Simulator: **100 passed, 0 failed, 0 skipped**.
  Result: `/private/tmp/yl-hls-probe-ios-green.xcresult`.
  Suites cover H264 Load through AVPlayer ready, Stop during a held HLS segment
  followed by a fresh Load, live HLS routing, HEVC fallback selection and timeline
  seeking, open cancellation, HLS resource loading, live buffering/reconnect,
  audio rendering, media clock, frame scheduling and fallback lifecycle.
- macOS 27.0 arm64: **35 passed, 0 failed, 0 skipped**.
  Result: `/private/tmp/yl-hls-probe-macos-green.xcresult`.
  Suites: `YlAppleHlsProbeTests`, `YlMacosAvPlayerStateTests`,
  `YlMacosOpenCoordinatorTests`, `YlMacosHlsTests`, `YlMacosAudioTests`.
- The previous live buffering/reconnect implementation in
  `YlAvPlayerBackend.swift` and clock implementations in `YlAudioRenderer.swift`
  and `YlMediaClock.swift` remain byte-for-byte identical to HEAD.
- The modified shared test fixture, its manifest hash and both example copies
  match; canonical fixture counts are 404 iOS and 346 macOS.

## Limits

The supplied remote playback URL and physical-device playback were not replayed.
HEVC route selection is tested before decoder construction; this is not a new
hardware HEVC playback claim.

The full example/fixture parity check still reports pre-existing iOS differences
in `YlFFmpegBridgeTests.swift`, `YlHlsManifestRewriterTests.swift`,
`YlLiveReconnectControllerTests.swift`, `YlOpenedMediaTests.swift` and
`YlVideoToolboxDecoderTests.swift`. Each discrepancy was confirmed in HEAD.
The new HEVC route test extends the existing example-only HEVC fixture tests;
historical fixture provenance was not rewritten.

Native commands use the existing generated-package deployment overrides
(`IPHONEOS_DEPLOYMENT_TARGET=15.0`, `MACOSX_DEPLOYMENT_TARGET=12.0`).
Existing Swift concurrency/deployment warnings remain. No full-matrix claim
is made.
