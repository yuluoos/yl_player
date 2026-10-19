# iOS RTMP policy test decoder isolation

Date: 2026-10-19. Follow-up to the four failures recorded in
[RTMPS verification](2026-10-19-rtmps.md).

## Root cause

The two `YlRtmpRestorationTests` cases and the two public time-seek cases in
`YlRtmpRouteTests` created real VideoToolbox hardware sessions while testing
retry/seek policy. On the selected iOS simulator, a temporary diagnostic logged
`VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) == false` for all four
cases. Each failed during initial managed-session construction with
`decoder.unavailable`, before reaching its policy assertions.

The managed pipeline uses a hardware-required VideoToolbox factory. When that
factory fails, ordinary decoder selection tries the software service, whose
production admission table is intentionally empty. The resulting error is
expected on this simulator; changing production hardware evidence or software
admission to make policy tests pass would change playback policy.

## Fix

A shared passive `RtmpPolicyVideoFactory` in the canonical test utilities now
enters through the existing host/coordinator `videoSessionFactory` seam.
Only these seek/restoration fixtures use it. The double releases submitted
packet reservations and emits no images; it supplies synthetic hardware
evidence strictly inside the tests. Existing managed-pause tests use the same
boundary isolation pattern.

Real RTMP/HTTP sockets, FLV parsing, session commit/deactivation/activation,
retry budgets, connection counts, public error codes and state/intent
assertions remain in use. No test was skipped and no assertion was relaxed.
The factory does not establish hardware support or actual decoded output.
RTMPS transport and AirPlay decoded-frame tests retain their previous paths.
Production code is unchanged. Canonical fixtures, iOS/macOS copies and affected
manifest hashes are synchronized; case counts stay iOS818/macOS863.

## Verification

- Fresh red run: four executed, four failed, zero skipped, with false H.264
  hardware capability and `decoder.unavailable` recorded for each.
  `/tmp/yl-rtmp-decoder-red.xcresult`;
  exported logs `/tmp/yl-rtmp-decoder-red-diagnostics`.
- First post-edit build caught an incorrect Swift argument order in the
  restoration fixture. Corrected before the subsequent test run.
- Focused green run: both complete classes, **12 passed, zero failed, zero
  skipped**, including the original four failures. No runtime warnings.
  `/tmp/yl-rtmp-decoder-green-fixed.xcresult`.
- macOS related regression (all nine RTMP classes and `YlAirPlayHostTests`):
  **73 passed, zero failed, zero skipped**. Seven generic main-thread runtime
  warnings, matching the earlier RTMPS run.
  `/tmp/yl-rtmp-policy-macos.xcresult`.
- Canonical/current example consistency (iOS818/macOS863), the three changed
  manifest hashes, public-surface validation and `git diff --check` pass.
- Final iOS related regression uses the same 73-case selection as the earlier
  failing run, with no exclusions: **73 passed, zero failed, zero skipped**.
  Seven generic main-thread runtime warnings, matching the previous AirPlay
  selection. `/tmp/yl-rtmp-policy-ios.xcresult`;
  `/tmp/yl-rtmp-policy-ios.log`.

These runs cover all nine RTMP test classes plus the AirPlay host class, not the
entire unrelated native suite. No physical-device decoding or receiver claim
is added by this test-fixture fix. Build logs also retain existing Sendable and
XCTest deployment-target warnings. No production files or public API changed.
