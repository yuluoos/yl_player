# Upstream playback failure diagnostics

Scope: shared Apple HLS/DASH loader and media proxy (iOS/macOS), native network
classification, Android Media3/FFmpeg and HTTP diagnostics, and the shared Dart
public message boundary.

- HTTP 403 keeps `network.http_forbidden`. Other known upstream statuses use
  `network.http_status.<status>` and include the status plus a fixed reason.
- URLSession DNS, timeout, TLS, offline, connection establishment and connection
  interruption failures retain structured causes. Source URLs, credentials,
  response bodies and arbitrary exception prose are not published.
- A bounded per-loader failure history feeds AVPlayer network/source failures.
  Same-resource success clears stale evidence. Cancellation clears history and
  prevents late callbacks from republishing it. Explicit decoder/container
  classifications retain precedence.
- Proxy logs distinguish upstream HTTP statuses from local synthetic 502 errors.

## Verification

The new Dart regression initially failed because HTTP 401 became
`Playback operation failed.` (`/tmp/yl-http-red.log`).

- Dart: 393 tests passed across Apple, Android, platform-interface suites and
  the public API test (`/tmp/yl-http-dart-focused.log`).
- Static analysis: Apple, Android and platform-interface packages passed
  (`/tmp/yl-http-analyze.log`).
- Native: 79 focused macOS tests passed, including the final response-diagnostic
  additions (`/tmp/yl-http-native-verified.log`).
- Canonical fixture/example parity: iOS 819 and macOS 866 cases verified.
  iOS native tests were not executed in this run.

Expanded regression is **not fully green**:

1. `YlApplePublicationTests.testHeldDisplayCallbackCannotAcquireNewBindingOrReviveStoppedOutput`:
   no decoded frame arrived for the new binding; the assertion expected a
   positive frame count (`/tmp/yl-http-native-final.log`). No baseline run was
   performed to attribute this failure.
2. `network_matroska_test.dart`: `range and policy 4096 HTTP-attempt cap bounds a repeated cache-thrashing scan`
   timed out at 30 seconds both in the expanded run and an isolated rerun
   (`/tmp/yl-http-matroska-rerun.log`). No baseline run was performed to attribute it.

Earlier stale wording expectations were updated. The expanded run's
`reply-before-idle adapter passes with immediate stopped identity fence` and
`platform registration does not escape the app barrel` timeouts passed in the
393-test rerun. The real proxy fixture rejects missing credentials with 401;
its initial 403 expectation was corrected after inspecting the fixture.

## Android native follow-up

- Preserve structured causes through Media3 playback errors, decoder readiness,
  candidate load rejection, committed failure publication and native fallback.
- HTTP 403 retains its stable code; other HTTP statuses include their actual
  numeric value and fixed reason. DNS, header deadline, read timeout, TLS,
  connection refusal/interruption and redirect limit have distinct diagnoses.
- HTTP attempt logs include actual upstream status, including retry responses
  previously represented internally as 599. No URL, credentials or response body
  is included. Request retry budgets are unchanged.
- HTTP Range and HLS byte sources retain failures across JNI exception clearing;
  successful reads clear that evidence. Failed native open/read/seek can surface
  the recorded cause. A generic InterruptedIOException alone is not proof of
  cancellation; only explicit cancellation evidence receives that code.
- Added coverage for real MockWebServer HTTP sources, retries and redirects,
  readiness futures, pending/committed session failures, replacement fencing,
  safe messages and the Dart boundary.

The initial transport-cause regression failed before implementation. The first
JDK 22 run also hit Mockito/ByteBuddy compatibility failures; subsequent native
runs use the installed JDK 17. An early full run's header-deadline timing test
failed and then passed on the next full run. A stale generic-message assertion
was updated to match the new fixed wording.

- Dart Android + platform-interface suites: 235 passed
  (`/tmp/yl-android-http-dart.log`).
- Static analysis of both packages: no issues
  (`/tmp/yl-android-http-analyze.log`).
- Android device playback and FFmpeg JNI instrumentation were not run; native
  validation here uses JVM unit tests and local HTTP fixtures.

- Final Android JVM suite: 555 passed, 3 skipped, no failures
  (`/tmp/yl-android-http-verified.log`; Gradle `BUILD SUCCESSFUL`).
