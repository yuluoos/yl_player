# P04 preliminary public-player capture

The entry has been exercised on native players; per-run evidence and limitations
are in the [P04 report](../../docs/superpowers/reports/2026-09-26-remaining-04-abr-live.md).
A successful capture is not complete CAP-ABR acceptance. Run native measurements
when other profiling/build work releases the machine. Run one
mode/attempt per fresh server, preserve every failure, and do not run modes
concurrently. Use a fresh unique run ID for each auto/caps/fixed attempt.

## Prepare and start the owned server

Generate the 40-second fixture as described in [README](README.md). Preserve the
preparer receipt: its `manifestSha256` becomes `YL_ABR_MEDIA_SHA256`. In a separate
terminal, from the repository root:

```sh
python3 -B tool/playback_network/network_profile.py \
  --root /private/tmp/yl-network-owned-40s \
  --profile down-and-recover-v1 --start-on-first-get --run-id abr-auto-001 \
  --log /private/tmp/abr-auto-001.requests.jsonl \
  > /private/tmp/abr-auto-001.server.jsonl
```

Read `profileSha256` from the startup row for `YL_ABR_PROFILE_SHA256`. This hash
is over the canonical normalized profile, not the entire profiles.json file.
The normal default still starts at server construction; the new option holds
the profile at its beginning until the first GET of a known asset. HEAD verifies
identities without starting the clock. A run can be armed only once; reconnects
do not reset it. The startup output and response headers report this mode.

## Capture one public session

From `packages/yl_player/example`, substitute the two recorded hashes:

```sh
/Users/yy2021_8689/flutter/bin/flutter test --no-pub \
  integration_test/abr_network_profile_test.dart -d macos \
  --dart-define=YL_ABR_RUN=abr-auto-001 \
  --dart-define=YL_ABR_MODE=auto \
  --dart-define=YL_ABR_URL=http://127.0.0.1:18779/manifest.mpd \
  --dart-define=YL_ABR_PROFILE=down-and-recover-v1 \
  --dart-define=YL_ABR_PROFILE_SHA256=PROFILE_HASH_FROM_STARTUP \
  --dart-define=YL_ABR_MEDIA_SHA256=MANIFEST_HASH_FROM_PREPARER \
  > /private/tmp/abr-auto-001.capture.log 2>&1
abr_exit_code=$?
printf '%s\n' "$abr_exit_code" > /private/tmp/abr-auto-001.exit-code
```

`caps` applies 320×180/350000 bit/s constraints at Load; `fixed` selects the unique
640×360/700000 track from the actual catalog before Play. No platform track IDs
are assumed. Automatic uses the default policy. First-frame timing uses the
correlated public event. The capture samples current-session state every 250 ms
after firstFrame, with one earlier post-Load observation, up to 180 s from Load
and 1024 records. It must reach natural completion at >=39.5 s; early EOF,
timeouts, failures and disposal failure are retained in the final record.

The fixed track command's ACK is recorded but does not prove its output settled;
automatic mode observed after that ACK is flagged separately. Geometry downgrade
checking begins after the first observed fixed 640×360 frame.
No such observation produces `fixed_high_unobserved`. Native ready/load/firstFrame
have separate finite timeouts. An outer four-minute test timeout is a guard;
missing final logs after a crash/hard timeout make the capture incomplete.

For iOS simulator or Android, use a verified target and ensure the device's
127.0.0.1 reaches this exact server (Android needs an explicitly configured port
forward). This document does not assert those routes/runners were tested. Remote
hosts, credentials, query strings and redirects are deliberately rejected.

## Close, then summarize

Stop the server with Ctrl-C after the player exits. Preserve its final shutdown
row; a forced kill or missing row cannot count as a complete capture. From the
repository root:

```sh
python3 -B tool/playback_network/summarize_capture.py \
  --capture /private/tmp/abr-auto-001.capture.log \
  --requests /private/tmp/abr-auto-001.requests.jsonl \
  --server-stdout /private/tmp/abr-auto-001.server.jsonl \
  --exit-code ACTUAL_FLUTTER_EXIT_CODE \
  --output /private/tmp/abr-auto-001.summary.json
```

Use the actual exit-code file, including nonzero values. Summary exit 0 means a
complete capture with no detected sampled policy violation; **not** full ABR
acceptance. Exit 1 preserves a failed/incomplete capture or detected policy
violation. Exit 2 rejects malformed/mixed/truncated evidence. All output paths
must be new. Keep source/dependency/build/device/OS identities in the enclosing
P08 manifest; this tool alone does not establish their equality across attempts.

The collector joins run/profile/manifest identities, unique contiguous request
IDs, request count with the server shutdown totals, sample count, monotonic
times, process outcome and cleanup. It checks caps against both known high-track
requests and public geometry/selected-track fields. Fixed output downgrade and
unexpected return to auto are separate findings. Unknown native metrics remain
null; counter resets or missing samples invalidate a counter delta.

`mediaRequestReachedRecovery` only says a media request with written bytes ended
at/after the 25 s recovery boundary. It does not measure bytes sent in that phase,
prove the player adapted, or require that requests spanned all earlier phases.
If media preloaded before the weak interval, the capture cannot quantify that
ABR response even if playback completes. Preserve this result; do not count it
as a successful weak-network trial.

Player times are Load-relative, HTTP times are first-GET-relative. After firstFrame,
the client brackets an identity-checked HEAD with its monotonic clock and records
`beforeUs`, `afterUs`, and the server's `X-Yl-Elapsed-Us`. The server time falls
inside that client interval; mapping a client observation back to profile time
therefore yields an interval, not a falsely precise point. HEAD never arms an
unused timeline. Old captures without this bracket remain supported and unaligned.

`downshiftLatencyUs` and `upshiftLatencyUs` are the first sampled public geometry
changes relative to the 10 s weak and 25 s recovery boundaries, with min/max bounds
from that clock bracket. They include playback-buffer delay and sample cadence;
they are **not** native ABR decision latency. A delayed downshift can first appear
after network recovery. `weakLowRequestLatencyUs` and
`recoveryHighRequestLatencyUs` report the first successful low/high video segment
request in those phases. `adaptationObserved` requires both request changes and
both output changes in a complete, violation-free automatic capture. It does not
prove causality or a quantitative SLO. `mediaRequestPhases` lists successful media
GET start phases. Unknown/rejected evidence never becomes a zero latency.
The legacy `adaptationLatencyUs` remains null because native decision time is unknown. Public geometry
switch counts are sampled observations and can include Period transitions;
they are not automatically ABR oscillations. State polling can miss short
buffering/quality events; maximum sample gap is retained. Native rebuffer deltas
are reported only when present and monotonic across all observed rows.

The outputs always retain `baselineComparable=false`, `capabilityAccepted=false`,
`physicalOutputVerified=false` and null end-to-end latency. Real RTT, live source
clocks, physical output, HTTP-FLV/RTMP, runtime live modes and P08 SLO freezing are
separate remaining work. Do not infer them from this VOD tool.

## P04 live mode capture (schema 1, prepared 2026-10-16)

`packages/yl_player/example/integration_test/live_mode_switch_test.dart` is an
explicit device-run entry point for **owned, loopback-only** HLS, HTTP-FLV and
RTMP fixtures. It is not part of offline tests. For each protocol provide
`YL_LIVE_RUN`, `YL_LIVE_PROTOCOL=hls|flv|rtmp`, `YL_LIVE_URL`,
`YL_LIVE_MEDIA_SHA256` (64 lowercase hex), and `YL_LIVE_OWNED=true`.
Use an explicit local port; HLS/FLV paths end in `.m3u8`/`.flv`, RTMP paths contain
an app and stream. Credentials, queries, fragments and non-loopback origins are
rejected. Device-local forwarding and the fixture server must be supplied by the
measurement owner; this test never configures global networking.

The test exercises automatic live default, smooth→paused low→playing low→smooth,
long pause/resume while low, repeated same-mode ACKs, rapid ordered requests,
replacement Load, and stale-command rejection after replacement and Stop. It waits
for authoritative idle after the Stop ACK (the ACK immediately fences commands).
Each observation records at least five seconds and allows up to twenty seconds
for progression after a declared stall; this finite test guard is not a latency SLO. It records
`YL_LIVE_SAMPLE` and `YL_LIVE_RESULT` JSON without URLs or exception text.
Snapshots require public media-clock progression. This does **not** establish
physical video output, audio output, source-clock delay, or weak-network SLOs.
`declaredMediaHash` is a declaration until joined to the same-run server receipt;
`endToEndLatencyUs` remains null. Failed/time-out runs and cleanup failures stay
in the result. Archive raw output, exact source/build/media/server identities and
independent A/V evidence before acceptance. Never count an unrun entry as passed.

Offline checks:

```sh
flutter test --no-pub packages/yl_player/test/live_mode_capture_test.dart
python3 tool/playback_network/check_live_mode_native.py --flutter-sdk /path/to/flutter
```

The Apple command compiles production Swift and checks policy/reducer/budget
behavior in a standalone process. It does not instantiate a playback session or
claim native media-path integration coverage. Android native coverage uses the
existing JVM suite; no device tests are needed for that suite.

### Connected iPhone sources

The live harness defaults to loopback. For a physical device, an operator may
explicitly declare `YL_LIVE_OWNED_HOST` equal to the literal private IPv4 address
in `YL_LIVE_URL`. Only RFC1918 IPv4 addresses are accepted for this opt-in;
public IPs, hostnames, credentials and query strings remain rejected. Bind an
owned forwarding listener only to that interface and the fixture's port, retain
the original loopback server receipts, and stop the forwarder after the run.
The flag is a source-ownership declaration, not independent proof. Record the
command, source hashes and server receipt together. The phone needs access to
that LAN and must allow local networking. This does not alter production URLs.
HLS capture performs 16 pairs of rapid low/smooth requests to expose native
command-admission ordering; FLV/RTMP use one pair to respect recovery budgets.

For a physical iPhone, use `flutter test --no-uninstall` during a capture batch
so Local Network consent survives between cases. The default uninstall resets
consent; a permission dialog can also interrupt an in-flight mode command.
The live result retains at most 32 application lifecycle transitions with the
public capture clock, so background interruptions remain distinguishable from
a foreground transaction failure. Complete platform permission setup before
timing a comparable experiment. Keep failed preflight/cancelled runs separately.
