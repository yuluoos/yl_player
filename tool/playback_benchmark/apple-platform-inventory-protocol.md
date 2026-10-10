# R4 local platform inventory and shared iOS verification

Base 6bc2bf3, 2026-10-09. Candidate/default/admission/global-bound stay false.
User confirms no extra equipment: complete locally executable verification.

Inventory is read-only: system_profiler hardware/software/audio/displays,
xcdevice, simctl, Xcode version and Runner showdestinations. Preserve unsuccessful
sandbox queries separately from host queries. Empty/failed enumeration is not
absence proof. Archive selected fields and command/byte/hash metadata; omit
personal names, UDIDs, serials and display identities. Raw local query outputs
are not embedded; their hashes do not make the archive a raw-output replay.
Only current host and connected/visible devices are enumerated, not remote Macs.

For shared iOS compatibility, use the already booted iPhone 18 Pro simulator,
iOS 27.0, arm64, existing Runner workspace and native-ios-tests DerivedData.
Source discovery finds678 methods; one is macOS-only, so canonical iOS runtime
identity count is677. Run that complete canonical suite once using XcodeBuildMCP test_sim:
Debug, CODE_SIGNING_ALLOWED=NO, ENABLE_TESTABILITY=YES, -sdk iphonesimulator,
-parallel-testing-enabled NO, test timeouts enabled with default60/max180s,
result bundle /private/tmp/yl-r4-ios.xcresult. No skip/only-testing filters,
no retries or timeout expansion to turn failures into passes. Preserve warnings,
failures, skips and missing cases; runtime manifest must match discovery, not just
XCTest exit status. Freeze source/test/fixture/bridge hashes before execution,
verify afterward and retain results plus exact tool arguments. Do not run heap,
MSL, other native tests or long playback concurrently. No physical phone install
in this local simulator slice. Simulator test execution is not physical iOS or
iOS15 validation; compile/link success is not a runtime result.

No system output, volume or sample rate changes. Built-in microphone/speaker and
external display enumeration do not establish calibrated AV capture. No actual
route switch, physical AV, minimum macOS12/iOS15 or Intel acceptance in this slice.
HardwareRequired/Dolby/DRM and the candidate's excluded iOS scope do not expand.
Mac full-suite and independent >=1200s final-version playback remain R5; do not
merge historical passes into this run. R4 stays partial while hardware-dependent
cells remain unavailable. R4/R5 success never overrides R3 resource non-admission.

## Diagnostic follow-up after initial failure

Initial run:677 identities present,673passed/1failed/3hardware skips. RTMP
backoff-resume test checked decoder construction150ms after socket acceptance,
which occurs before asynchronous media/decoder preparation. Preserve this result.
Add a test-only300ms delay on recovery decoder construction and run that case
once with old assertion to reproduce RED. Then wait for actual construction
within the original2s reopen deadline (no deadline increase), retain thread and
retry/stop assertions, and run the complete iOS suite under a new source identity.
No production code changes. Run the four mirrored macOS RTMP pause tests once
as the affected-platform check; this is not R5 full macOS/long-run acceptance.
New result directories:yl-r4-ios-red,yl-r4-ios-fixed,yl-r4-macos.
