# yl_player_source_resolver

Optional source resolution module. `yl_player` does not depend on this package.
The application explicitly resolves a script before passing a supported media
source to the player.

The native bridge embeds the pinned MIT QuickJS 2026-06-04 core on Android, iOS
and macOS through Dart build hooks. Each resolution owns a native worker and
separate runtime. No CLI process, std/os helpers, filesystem API, native module
loader or network library is exposed to scripts. Network requests use a bounded
synchronous host queue serviced asynchronously by Dart.

Native cancellation and monotonic deadlines interrupt JavaScript (including
regular expressions) and wake host waits. Terminal status is published after
context/runtime destruction; closing the Dart handle joins the worker and frees
its remaining handle. Callers must await cancellation/close; a Dart timeout alone
is not execution termination.

Native limits independently enforce 512 KiB source, 8 KiB parameters, 64 KiB JSON
result, 8–64 MiB heap, 256 KiB–1 MiB stack, at most 30 seconds, four active runtimes,
eight host requests, 64 KiB request JSON, 1 MiB reply JSON and 4 MiB total replies.
The default timeout/heap/stack are 10 seconds / 16 MiB / 512 KiB. Transport adds
its own byte/deadline/redirect checks. JSON encoding overhead counts toward native
queue byte bounds.

Errors carry fixed classifications without serializing script exceptions. The
unmodified engine's stack-limit exceptions are ordinary catchable JavaScript
exceptions: an uncaught one is reported as execution failure, and recovery is
permitted within the enforced stack bound. Cancellation, deadline, allocation
failure, unsupported host API, queue bounds and host transport failures are
sticky control-plane failures even if script code catches an exception.

This is an in-process bounded VM, not process-level isolation against native
engine vulnerabilities. Platform runtime and controlled sample evidence are
recorded separately; desktop execution does not establish mobile execution.

## Focused native verification

Run from this package directory so Flutter includes this optional package's hook:

```sh
flutter test --no-pub test/native_runtime_test.dart
```

The standalone C harness exercises the same embedded runtime directly; it is a
test executable, not a production runtime substitute. Its command is documented
in `tool/test_native.sh`; set `SANITIZE=1` for AddressSanitizer and UBSan.

Upstream license and exact file hashes are under `src/quickjs/`.

## Explicit application use

```dart
final resolver = YlScriptResolver();
final pending = resolver.resolve(YlScriptReference.parse(reference));
try {
  final resolved = await pending.result;
  final session = await player.load(resolved.toNetworkSource());
  await session.play();
} on YlScriptException catch (error) {
  // Show fixed error.message; record only code/phase/diagnosticId.
} finally {
  await resolver.dispose();
}
```

Keep the current `YlScriptResolution` to `await pending.cancel()` when replacing
an input. Use an application generation counter before accepting results and
serialize player load/stop operations. Cancellation is distinct from failure.
`expiresAt` is unknown unless the script explicitly returns the supported UTC
value; refresh is always an explicit new resolution. `toNetworkSource()` accepts
a valid header-free RTMP or RTMPS app/playpath URI and preserves live intent,
explicit ports and encoded query data. Both reject HTTP headers with
`script.invalid_headers` and recheck expiry before conversion. Conversion
delegates playback to the core player's native route and policy checks; this
resolver supplies no RTMP engine. RTMPS playback is supported by the Apple
adapter; Android still rejects it during native assessment. On iOS/macOS, pass
the converted source to `player.load` with
`options: const YlLoadOptions(airPlay: true)` to use the existing live AirPlay
bridge. Its codec and receiver/network limits still apply; see
[AirPlay support](../../docs/airplay.md).
Do not log returned URLs, headers, parameters or script text.

## Separate optional example

`example/` explicitly depends on both the player and this module. It downloads
an owned synthetic script from its own loopback server, resolves it using the
public API, and plays the bundled 4-second AVC fixture. Playback header normalization is
verified separately; this MP4 handoff does not claim headered MP4 support on Apple. Resolve/refresh, cancellable work, and cancel/stop demonstrate generation
handling. No business subscription controller or downstream service is included.
Target floors are Android API24, iOS15 and macOS12.

Run `flutter run -d macos` (or an iOS/Android device) from `example/`.
The bundled media provenance and SHA-256 are in `example/assets/PROVENANCE.md`.
The example permits local HTTP for its synthetic fixture; applications should
choose their own transport policy.

## Device acceptance without private scripts

From `example/`:

```sh
flutter test --no-pub integration_test/script_runtime_test.dart -d DEVICE
```

This checked-in entry exercises the actual public native runtime, deadlines,
live cancellation, socket disconnect, memory bounds/reuse, header-free RTMP
and RTMPS conversion,
and actual `YlPlayerView` HTTP handoff/first frame. It has no private fixture import.

`integration_test/rtmp_handoff_test.dart` is the focused owned-JavaScript RTMP
handoff case. Run it with the repository's `tool/rtmp_acceptance/run.py` wrapper,
which starts the pinned independent MediaMTX peer and owned publishers. Pass
`--dart-define=YL_RTMP_HOST=10.0.2.2` on Android Emulator; Apple uses loopback.
This integration entry is separate from the example's HTTP demo UI.

The exact nine-original acceptance entry is generated only when the restricted
archive is available. From this package directory:

```sh
python3 -B tool/generate_controlled_integration.py --archive /absolute/restricted/archive --verify-only
python3 tool/generate_controlled_integration.py --archive /absolute/restricted/archive
cd example
flutter test --no-pub integration_test/generated/controlled_runtime_test.dart -d DEVICE
cd ..
python3 tool/generate_controlled_integration.py --remove
```

The generator validates each original-byte hash against the shared safe manifest,
refuses an unignored output, and writes the complete entry with mode 0600 inside a
0700 directory. Do not commit the generated entry or retain build artifacts that
embed originals. The source archive itself remains restricted and unchanged.
`--verify-only` enforces a 512 KiB source limit and emits a JSON receipt with all
nine IDs, expected/observed SHA-256, byte counts and fixed verification statuses.
It does not generate a Dart entry, run JavaScript, download anything or use a
device. A missing or changed script remains a failed row; any failure exits 1.
The archive directory and script files must have no group/other permission bits
(normally 0700/0600); symlinks and non-regular inputs are rejected. Generation
validates all nine originals before atomically replacing the ignored entry.
Output path components cannot be symlinks, and tracked output is refused.
`--remove` follows the same output-path checks and never removes the source archive.
This tool assumes a trusted local checkout; it is not a sandbox against another
process changing the repository or its permissions concurrently.

Run the offline generator regressions from the repository root:

```sh
python3 -B -m unittest discover -s packages/yl_player_source_resolver/tool -p 'test_*.py' -v
```

These tests use owned synthetic scripts, include parity against the frozen
historical ledger, and require only Python and Git. The private archive is not
needed. A successful audit proves current byte retrieval; keep a separate
restricted backup when moving or removing this checkout. It does not establish
runtime compatibility or current downstream service availability.

The generated entry reuses `test/support/controlled_contract.dart`; every host
exchange is intercepted by controlled fixtures, and real returned downstream URLs
are inspected only through safe predicates/digests, never fetched or logged.
JS-09 has no host request, so failed-host/malformed-host cases do not apply.
The generated entry also registers nine real-player handoffs. Each rechecks the
original hash, resolves under that controlled host, converts the result using
`toNetworkSource`, and explicitly replaces only the final URI with an owned
loopback HLS. It preserves the request object and source options, matches the
native session/first-frame event and video geometry, observes a media request,
then stops without a late frame. This does not fetch the original online media
or attest physical audio/video. The demo server rejects mismatched expected credentials on manifest and media
requests, and the handoff checks application credentials for the header-bearing
scripts. Accept-Encoding remains native transport negotiation, so the fixture
does not require unsupported compression offers to be forwarded verbatim.
Platform evidence and remaining limitations are recorded in the repository's
`docs/superpowers/reports/2026-09-22-script-resolver.md`.

Acceptance recorded 2026-09-22: macOS covered all26 cases through an initial25
passes plus a successful focused handoff rerun; iOS27 arm64 simulator and Android
API36 arm64 emulator each passed the full26-case app suite. This includes the
shared19 exact-original controlled cases and real AVPlayer/Media3 firstFrame.
Physical devices and runtime execution at the minimum supported OS floors were
not tested. The initial macOS handoff correctly rejected headered MP4; the final
owned fixture uses header-free MP4. No native hook/player fix was required.

Settled `YlScriptResolution.timings` provides immutable monotonic wall-clock
`input`, `download`, `evaluation`, `host`, `result`, `cleanup`, and `total`
durations. Before settlement it is null; unvisited phases remain null even on
failure. Repeated host/evaluation phases accumulate. Evaluation includes VM
polling; host includes request waits. These are not CPU/heap measurements, and
contain no script/URI/credentials. The optional example's `P08_SCRIPT_HANDOFF`
records the corresponding public first-frame boundary separately.
