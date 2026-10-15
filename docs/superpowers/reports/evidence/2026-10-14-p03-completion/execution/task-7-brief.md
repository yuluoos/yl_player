## Task 7: 三端实际输出和公开错误契约

**Files:**
- Modify: `packages/yl_player/example/integration_test/format_matrix_test.dart`
- Create: `packages/yl_player/example/integration_test/decoder_budget_test.dart`
- Modify: `packages/yl_player/example/integration_test/support/capture_composition.dart` only if format capture needs a reusable helper
- Create: `tool/media_matrix/observations.py`, `test_observations.py`
- Modify: `tool/check_native_macos.sh`, `tool/check_native_ios.sh`, `tool/run_android_integration.sh` only to register actual new test discovery where needed
- Modify: package failure adapter tests if existing internal codes do not map to public `YlFailureCodes.decoderUnavailable`/`resourceExhausted`

**Interfaces:** Preserve existing `YL_FORMAT_ROW` identity and add separate fields for `pixelMarkersVerified`, `pcmMarkersVerified`, `audioClockUs`, verification method and failure stage. Native PCM assertions produce their own evidence keyed by fixture SHA; don't copy their result into a Dart run unless the native measurement is from that same run.

- [ ] Write observation validation RED: missing planned rows, duplicate identities, mismatched media/build hashes, marker failure with lifecycle success, and skipped software rows cannot yield full acceptance. Independent host decode remains `playerOutputVerified=false`.
  Required and diagnostic denominators are emitted separately using Task 2's pinned classification; a diagnostic rejection is never added to the supported count.
- [ ] Extend the matrix test to sample real displayed colors at 0/1/2/3-second markers and after seek; use P02 capture helpers on Apple and actual texture capture on Android. Wait for marker observation, not just seek acknowledgement. Preserve both captures on mismatch; a host scale change is a failed run requiring a fresh run identity.
- [ ] Use native real-decoder PCM tests for tone, channel order/downmix, leading/trailing samples and seek/track-switch alignment. Reuse P01 PCM tap seams; do not expose a production debug endpoint or infer sound from selected audio track. Add AC-3 5.1, E-AC-3, DTS, FLAC controls.
- [ ] Add real public failure assertions:

```dart
// failure comes from the actual load/play exception for an owned test source.
expect(failure.code, YlFailureCodes.decoderUnavailable);
expect(failure.retryable, isFalse);
```

  Controlled native budget exhaustion additionally checks `resourceExhausted`, session/command scope appropriate to the stage, one terminal event and cleanup. No synthetic `YlPlayerFailure` constructed merely to pass the public test.
- [ ] Run native and public tests sequentially per platform. Example from `packages/yl_player/example`:

```sh
flutter test integration_test/format_matrix_test.dart -d macos --dart-define=YL_FORMAT_REQUIRE_SUPPORT=true
flutter test integration_test/decoder_budget_test.dart -d macos
```

  Supply P02's existing `P01_CAPTURE_URL` helper for Apple capture. Repeat with the available iOS simulator and Android wrapper. Strict runs may expose genuine still-open requirements; fix implementable failures, preserve unavailable device rows. Do not make unsupported required cases pass by changing expected outcome to rejection.
- [ ] Expected GREEN for implemented admitted combinations: actual image/PCM/lifecycle assertions and exact public errors. Full CAP-FORMAT stays open if any confirmed combination still lacks implementation/evidence. Commit tests and measured per-platform observations.

