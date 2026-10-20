# Owned RTMP application acceptance

`run.py` starts the previously verified MediaMTX **1.21.1** release from
`/private/tmp/yl-rtmp-foundation`; it never downloads binaries. It verifies both
the pinned release archive and extracted executable, and the repository-owned
H.264/AAC fixture. See the phase report for provenance/checksums.

## Fresh setup on the supported runner host

This runner is pinned to **macOS on Apple Silicon (`Darwin arm64`)**. Python 3.11+
is required. Its publisher prerequisite is an installed FFmpeg executable at
`/opt/homebrew/bin/ffmpeg` (the acceptance used FFmpeg 8.0.1). The runner does not
install FFmpeg; provide that Homebrew location before running it. Stream-copy
requires FLV/H.264/AAC and RTMP support. Application acceptance additionally needs
your Flutter SDK and the corresponding platform SDK/device; use its absolute
Flutter path in the commands below. No server tooling becomes a product dependency.

The exact peer asset is
[`mediamtx_v1.21.1_darwin_arm64.tar.gz`](https://github.com/bluenviron/mediamtx/releases/download/v1.21.1/mediamtx_v1.21.1_darwin_arm64.tar.gz).
Archive SHA256: `25e20ed41611f1f3103b8359585210b29b11b69fa0d9e11bd11b92f7bbcb42ef`.
These fresh-bootstrap commands **download, verify and extract only**; they do not
execute MediaMTX. The subshell stops if architecture or checksum verification fails.
The downloaded asset is stored under the shorter filename expected by the runner.

```sh
(
  set -eu
  test "$(uname -sm)" = "Darwin arm64"
  test -x /opt/homebrew/bin/ffmpeg
  mkdir -p /private/tmp/yl-rtmp-foundation
  cd /private/tmp/yl-rtmp-foundation
  curl --fail --location --output mediamtx.tar.gz https://github.com/bluenviron/mediamtx/releases/download/v1.21.1/mediamtx_v1.21.1_darwin_arm64.tar.gz
  printf '%s  %s\n' 25e20ed41611f1f3103b8359585210b29b11b69fa0d9e11bd11b92f7bbcb42ef mediamtx.tar.gz | shasum -a 256 -c -
  tar -xzf mediamtx.tar.gz mediamtx
  python3 - <<'VERIFY'
import hashlib
from pathlib import Path
import tarfile
with tarfile.open('mediamtx.tar.gz') as archive:
    expected = hashlib.sha256(archive.extractfile('mediamtx').read()).digest()
assert hashlib.sha256(Path('mediamtx').read_bytes()).digest() == expected
print('Extracted executable matches the verified archive; not executed.')
VERIFY
)
```

For an existing verified tool directory, skip downloading/extracting again. The
runner independently checks the archive SHA, extracted executable identity and
owned fixture SHA before execution. To inspect the installed FFmpeg prerequisite,
run `/opt/homebrew/bin/ffmpeg -version`; no new installation is needed on the
recorded acceptance host. The following run command is the separate action that
starts the verified server, publishers and your selected test command.

## Execute acceptance

From `packages/yl_player/example`:

```sh
python3 ../../../tool/rtmp_acceptance/run.py -- python3 ../../../tool/run_with_display_awake.py /absolute/flutter/bin/flutter test integration_test/rtmp_playback_test.dart -d macos --no-pub --reporter expanded
```

For iOS use the selected Simulator ID in place of `macos` (no display-awake
wrapper needed). For a coldboot Android Emulator use its device ID and
`--dart-define=YL_RTMP_HOST=10.0.2.2`. Builds must remain serialized.
For the optional resolver use its example directory and target
`integration_test/rtmp_handoff_test.dart`. No resolver dependency is added to core.

The independent server binds only `127.0.0.1:19350`; all other protocols and
management endpoints are disabled. Installed FFmpeg loops the owned fixture
with stream-copy to `live/owned`, and with `-an` to `live/video`. It is test
fixture tooling, not a shipped dependency.

The test proxy binds `127.0.0.1:19351`, forwards raw RTMP to MediaMTX without
parsing/changing protocol messages, and caps readers at eight. Its loopback
HTTP control endpoint `:19352` caps concurrent controls at four and headers at
8 KiB. `/silent` affects newly accepted clients (consumes/discards their setup
bytes); `/hold` retains downstream bytes while still draining MediaMTX;
`/release` delivers them; `/drop` closes reader sockets; `/normal` clears fault
modes; `/stats` reports bounded counters/history. Held output is limited to
8 MiB per reader; overflow is a visible fixture failure and connection close.
Stream reads/writes use 64 KiB chunks and writer backpressure. No recordings
or unbounded client/history lists are retained.

Each run creates a unique log directory under the tool root with server and
publisher logs, exact configuration, and a final `proxy.json` receipt even on
nonzero command exit, timeout or cancellation. `outcome.kind` distinguishes
`success`, `nonzero_exit`, `timeout`, `cancelled` and `error`;
`outcome.commandExitCode` is set only when the command completed. The separately
reported `observedCommandReturnCode` can reflect termination during cleanup.
`cleanup.complete`, its proxy task/read/control counts, and per-group TERM/KILL,
remaining-group and leader-exit fields distinguish a fully drained snapshot from
incomplete cleanup. Receipt persistence errors are explicitly printed to stderr;
they never replace the original command exit or exception.

The command deadline is 20 minutes. Proxy task cleanup is bounded to 2 seconds;
each recorded process group gets up to 5 seconds after TERM, then KILL with a
2-second group wait and a bounded 2-second leader join if needed. Group cleanup
continues even if its launcher has already exited, and repeated cancellation
cannot interrupt the bounded cleanup/receipt path. Normal/nonzero command exits
retain their exit code; timeouts and cancellation propagate as before. Exit,
SIGTERM and cancellation clean only recorded child process groups. Port collisions fail setup; the harness never kills processes by port.
The caller owns any device boot and entrypoint-config restoration.

The test's `firstFrame` evidence is the mounted public view and matching session.
Recovery uses Apple accepted-presentation counting; Android additionally uses
the existing debug-source-set read-only AnalyticsListener/surface observer.
The one-shot public firstFrame future is never reused as recovered-frame proof.
Missing-stream candidate survival proves **public session preservation**; it
does not directly observe lease transfer or prove post-lease rollback. Native
canonical AVIO/coordinator tests supply separately labeled restoration evidence.

## Focused runner regressions

With the verified peer and FFmpeg prerequisites already present, from the
repository root:

```sh
python3 -B -m unittest discover -s tool/rtmp_acceptance -p 'test_run.py' -v
```

These seven bounded tests use only owned local peers/process groups. They cover
success, nonzero exit, shortened test-only command timeout, cancellation,
exited launcher descendants and a descendant that ignores TERM after its launcher
exits, plus a mocked read-only permission/retirement probe. The production
acceptance deadline remains 20 minutes. They do not boot any device or rerun
Flutter/native playback suites.

## P05 business subscription fixture

`business.py` wraps the same pinned peer with a bounded loopback HTTP server
(port 19353), a deterministic two-channel M3U, and a JS resolver script. From
TVS, run:

```sh
python3 /path/to/yl_player/tool/rtmp_acceptance/business.py -- \
  flutter test integration_test/live_subscription_playback_test.dart -d macos --no-pub
```

It supplies the run identity, exact subscription SHA-256 and RTMP fault-control
origin as `P05_*` defines. Conflicting P05 defines (including split and short forms) and define files are rejected. The
channels exercise direct RTMP and JS-to-RTMP; they do not replace the nine frozen
private-script contracts. The TVS entry verifies three native recoveries, a
fourth terminal drop without extra business retries, explicit recovery, refresh
preservation, late-result isolation and awaited provider disposal. The tool
emits separate fixture and process cleanup receipts; TVS emits safe
`P05_RECEIPT` JSON. No claim of physical audio/video or latency follows from them.

For Android, arrange and later remove owned reverse forwards for 19351, 19352
and 19353 on the explicitly assigned emulator. This runner does not configure
devices. Busy ports fail without terminating existing listeners.

Run all runner and fixture tests from the player root:

```sh
python3 -B -m unittest discover -s tool/rtmp_acceptance -p 'test_*.py' -v
```
 The fixture-only
`test_business.py` tests need no MediaMTX/FFmpeg. `test_run.py` uses the pinned
peer and now covers an exited command whose descendant keeps a silent reader
open: listeners close before bounded reader cancellation, and listener draining
happens afterward. The cleanup receipt includes `listenersClosed`. Test-only
short command deadlines start after fixture readiness (bounded to five seconds),
so interpreter startup is not confused with termination behavior.
