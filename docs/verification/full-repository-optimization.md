# Full Repository Optimization Verification

Date: 2026-09-04

## Environment

- Flutter 3.44.0 stable, Dart 3.12.0.
- Local Android verification: OpenJDK 22.0.1. CI pins Temurin Java 17.
- Xcode 26.6 (17F113).
- iPhone 17e Simulator, iOS 26.5 (23F77), arm64, UDID
  `BE1D20AE-8A22-4279-ADF8-9056CFA55371`.

## Automated evidence

- Foundation: **PASS** — `sh tool/check_foundation.sh` completed with no
  analysis issues, 64 Dart/example tests passed across seven test groups, the
  iOS FFmpeg build contract passed, and 45 Dart files required no formatting
  changes.
- Android native: **PASS** —
  `./gradlew testDebugUnitTest --warning-mode all` completed with 60 tests
  passed across nine result suites and no failures.
- iOS native: **PASS** — `sh tool/check_native_ios.sh` produced an Xcode result
  with 187 tests passed, two skipped, and zero failed out of 189 total. Both
  skips require a VideoToolbox hardware H.264 session that this Simulator
  runtime does not expose.
- iOS integration: **PASS** — all nine cases passed across the required HLS,
  local MKV, network Range/sequential MKV, HTTP-FLV reconnect, and
  authenticated-HLS suites.
- Contract audits: **PASS** — Android strips `Authorization`, `Cookie`, and
  `Proxy-Authorization` across origin changes; per-platform Dart channel codec
  duplicates are absent; Android and iOS emit protocol-versioned,
  generation-scoped state deltas; iOS emits no legacy `droppedFrames` key; and
  `git diff --check` reported no whitespace errors.
- CI definition: **PASS (local parity)** — `.github/workflows/ci.yml` parses as
  YAML and its foundation, Android, simulator-selection, and iOS commands all
  passed locally. A hosted GitHub Actions run requires pushing the commits.

## Warning status

- The Flutter 3.44 generated Android hosts still require
  `android.builtInKotlin=false`, `android.newDsl=false`, and the external Kotlin
  Android plugin. Gradle reports their AGP 9 deprecations plus the embedded
  Kotlin 2.2.0/requested 2.2.20 warning. Removing these compatibility paths was
  tested and prevents Flutter plugin configuration, so the warnings remain
  documented rather than hidden.
- Direct Xcode verification can report stale files outside its current output
  root after Flutter integration tests switch generated build directories. The
  fresh run completed with zero test failures; this is a non-fatal build-cache
  cleanup warning.

## Deferred evidence

- Android TV physical-device endurance: **UNVERIFIED**.
- Physical iOS VideoToolbox availability and playback: **UNVERIFIED**.
- Long-duration playback and reconnect soak: **UNVERIFIED**.
- Instruments, ETTrace, and memgraph profiling: **UNVERIFIED**.
- Hosted GitHub Actions execution: **UNVERIFIED until pushed**.
