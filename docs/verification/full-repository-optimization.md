# Full Repository Optimization Verification

Date: 2026-09-04

## Environment

- Flutter 3.44.0 stable, Dart 3.12.0.
- Local Android verification: OpenJDK 22.0.1. CI pins Temurin Java 17.
- Xcode 26.6 (17F113).
- MacBook Pro (`MacBookPro17,1`), Apple M1, 16 GB, macOS 26.6.2
  (25G83), arm64.
- iPhone 17 Pro Simulator, iOS 26.5 (23F77), arm64.

## Automated evidence

- Foundation: **PASS** — `sh tool/check_foundation.sh` completed with no
  analysis issues, 70 Dart/example tests passed across eight test groups, the
  iOS and macOS FFmpeg build contracts passed, and 53 Dart files required no
  formatting changes.
- Android native: **PASS** —
  `./gradlew testDebugUnitTest --warning-mode all` completed with 60 tests
  passed across nine result suites and no failures.
- iOS native: **PASS** — `sh tool/check_native_ios.sh` produced an Xcode result
  with 194 tests passed, two skipped, and zero failed out of 196 total. Both
  skips require a VideoToolbox hardware H.264 session that this Simulator
  runtime does not expose.
- iOS integration: **PASS** — all nine cases passed across the required HLS,
  local MKV, network Range/sequential MKV, HTTP-FLV reconnect, and
  authenticated-HLS suites.
- macOS native: **PASS** — `sh tool/check_native_macos.sh` produced an Xcode
  result with 34 tests passed, zero skipped, and zero failed. Its FFmpeg build,
  source/artifact checksum, and live-callback contracts also passed.
- macOS universal build: **PASS** — the release application executable,
  FlutterMacOS framework, Dart App framework, and YlFFmpegBridge framework all
  contain `arm64` and `x86_64`; the plugin object compiled and linked for both
  architectures; the application declares macOS 12.0; its signed Release app
  includes the loopback-server entitlement; and the final `x86_64` executable
  passed a Rosetta smoke launch.
- macOS integration: **PASS** — seven cases passed across five suites covering
  AVPlayer HLS, local H.264/AAC MKV and audio-track switching, HTTP Range and
  sequential-200 MKV, HTTP-FLV forced reconnect, and authenticated HLS.
- Contract audits: **PASS** — Android strips `Authorization`, `Cookie`, and
  `Proxy-Authorization` across origin changes; per-platform Dart channel codec
  duplicates are absent; Android, iOS, and macOS emit protocol-versioned,
  generation-scoped state deltas; iOS emits no legacy `droppedFrames` key; and
  `git diff --check` reported no whitespace errors.
- CI definition: **PASS (local parity)** — `.github/workflows/ci.yml` parses as
  YAML and its foundation, Android, simulator-selection, iOS, and macOS commands
  all passed locally. A hosted GitHub Actions run requires pushing the commits.

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
- Flutter 3.44 reports that the generated macOS runner still has CocoaPods
  integration while every current macOS plugin is available through Swift
  Package Manager. The non-standard Podfile and custom Xcode configurations
  make automatic migration unsafe, so this remains a documented packaging and
  build-time warning rather than an unreviewed project rewrite.
- CocoaPods reports `DART_DEFINES` parsing and custom base-configuration
  warnings during direct macOS XCTest setup. The workspace still compiles,
  links, and passes all 34 tests. Flutter integration tests can also print
  `Failed to foreground app; open returned 1` while the launched test process
  continues and every assertion passes.

## Deferred evidence

- Android TV physical-device endurance: **UNVERIFIED**.
- Physical iOS VideoToolbox availability and playback: **UNVERIFIED**.
- Intel macOS physical-device runtime: **UNVERIFIED**; no Intel Mac was
  available. Intel compile/link and Rosetta smoke are verified separately.
- Long-duration playback and reconnect soak: **UNVERIFIED**.
- Instruments, ETTrace, and memgraph profiling: **UNVERIFIED**.
- Hosted GitHub Actions execution: **UNVERIFIED until pushed**.
