# Android host integration runner

`run_android_integration.sh SUITE [flutter-test arguments...]` remains the shell
entry point. Set `YL_ANDROID_DEVICE_ID` to the intended device. `YL_ADB` and
`YL_FLUTTER` optionally select executable paths (not shell command strings).
The caller's working directory remains the Flutter example directory.

The Python standard-library runner applies one monotonic execution budget to
API discovery, previous logcat capture/clear, Flutter and marker-driven HOME /
foreground commands. Defaults: 600 seconds execution, 15 seconds per adb call,
30 seconds cleanup. `YL_ANDROID_RUN_TIMEOUT_SECONDS`,
`YL_ANDROID_ADB_TIMEOUT_SECONDS`, and `YL_ANDROID_CLEANUP_TIMEOUT_SECONDS` may
shorten these budgets for diagnostics; values cannot exceed those defaults.
Flutter's own test timeout remains 5 minutes. These are host orchestration
limits, not playback/performance acceptance thresholds.

Every command starts a new POSIX session. Cleanup signals only those owned
process groups, first TERM then KILL if needed. Confirmed retired groups are
never looked up or signalled again, avoiding later identifier reuse. Failure to
inspect a group does not prove release. A completed adb client with lingering
same-session helpers is treated as failure. Global adb/Gradle daemons or children
that deliberately detach into another session are outside this group ownership
contract; no global kill/restart or process-name matching is performed.

SIGINT, SIGTERM and SIGHUP use the same cleanup path. If HOME was attempted but
foreground was not confirmed, cleanup attempts restoration on the selected
device. Restoration and failure-logcat capture share the cleanup budget with
process retirement; they never start a fresh unbounded wait. The original test
exit is retained on diagnostic failure. Timeout exits 124; signals use128+signal;
configuration errors exit2; unavailable commands exit127. A successful test with
unconfirmed group cleanup or failed required foreground restoration exits70.

API discovery parses only stdout; adb daemon startup/diagnostic stderr is
retained separately and named in the command receipt. After command cleanup
and log replay, the runner restores caller signal handlers, then freezes the
receipt outcome. Interruptions received during replay are included; later
signals follow the caller policy rather than changing a finalized record.

The output names an original Flutter log and `.receipt.json`. The receipt
separates primary/final exit, timeouts, actual device/API command, signal,
restoration and group retirement. Failed and interrupted runs remain failures.
Previous and failure logcat files remain beside the log. Log replay/receipt I/O
uses normal host filesystem/stdout semantics; these budgets bound owned command
execution and cleanup, not a blocked output sink or kernel filesystem operation.

Flutter can enumerate other devices internally despite `-d`. This wrapper does
not alter Flutter's device selection, restart an unresponsive device or prove a
simulator hang's root cause. Its own Flutter command group must still terminate
within the execution/cleanup budgets. No host orchestration receipt proves
physical output, the player's full resource bounds or release qualification.

Host regression command (no SDK/device needed):

```sh
python3 -B -m unittest tool.test_android_integration_runner tool.test_android_scripts tool.test_player_v2_gate
```
