# Natural EOF replay and host lifecycle verification (R1)

Base c98daef; use the existing 4.021 s local AVC/AAC fixture and actual macOS
host, decoder and AVAudioEngine, with the mixer muted. Candidate remains
internally injected and disabled by default. This is functional evidence,
not physical output, long playback, memory bounds or a latency comparison.

Run six methods serially: default/candidate natural EOF seek/replay (new),
default/candidate EOF suspend/resume (new), and the existing two manual-stop
replay tests whose helper is reused. No direct native pause/stop in the new
paths; production seek, suspend and close retain their own teardown behavior.

Natural replay: complete initial playback, seek to 0 and replay, then seek to
2000 ms and replay. Preserve host/session/output/node set. Check actual mode
submissions/anchor, native audio time and public position progress, real texture
frames, one first-frame event per session, and one completion per pass. Inject
one captured original-generation completion during paused/playing/closed stages.
The manual-stop helper records a null stop duration and manualStop=false for
this variant; it must not report a measured zero-cost stop.

Host lifecycle: after natural EOF, suspend twice, check retired graph stopped
and detached plus ledger zero, then resume twice. Existing contract preserves
session but rebuilds one native output; the old output must not be reused.
Foreground must settle paused, retain end position (100 ms observation tolerance),
keep playback intent false and avoid new completion or autoplay. Allow a 150 ms
settling interval, then inject retired callbacks and verify another 200 ms of
stable position, submissions and frames. Explicit seek0/play must advance native
and public clocks, publish video, and complete once more. First-frame publication
remains once per session. Repeated close and resume-after-close must remain inert.

Normal callbacks are forwarded transparently; one bounded capture is retained
solely for late-callback injection and released on exit. Native callback counts
are unobserved, not zero. Captures prevent using this run as retention evidence.

Per-method XCTest watchdog 90 s. Existing progress waits remain 5 s for start,
3 s for a further 200 ms, 10 s for EOF; foreground restore wait is 10 s. Keep
initial failures and source identity; do not relax deadlines or observation gates
following a failure. Export XCTest summary/tests/attachments and freeze final
source/fixture/binary hashes. A failed assertion invalidates the test even if its
attachment contains later observations. Mirror parity/discovery also required.

Host suspend/resume calls here exercise real resource teardown/reactivation;
they do not simulate an OS sleep, physical route switch, iOS background execution
or lowest-supported-system behavior. No new production change is presupposed.
