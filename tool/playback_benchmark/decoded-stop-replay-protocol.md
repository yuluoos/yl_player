# Same-session EOF stop and replay characterization

Base: 195e0d4. Verification runs on macOS; production candidate remains disabled.
The failing characterization also justifies a minimal shared replay-path fix.

Use the existing local `mkv-avc-aac.mkv` (about 4.021 s, AVC/AAC), with the
real host, demux, decoders, AVAudioEngine and native player. Run default and
candidate test methods serially in the same freshly built test suite. This is
a functionality characterization, not an independent-process latency comparison.

Each method loads once and completes three passes: initial playback, seek to
0 ms after natural EOF and direct native `stop()`, then seek to 2000 ms after
the second natural EOF and another direct stop. Keep the same host, session,
renderer, engine and attached nodes throughout. Verify native sample time and
public position advance together, actual audio submission modes, one public
first-frame event per session, and one completed event per pass. Resource
ownership must drain at every EOF. Seek from completed must remain paused until
explicit play.

Capture at most one real played completion from the original generation and
invoke it twice while paused after each seek, once during each resumed pass,
and twice after repeated close. Normal native callbacks are forwarded unchanged;
their counts are unobserved. Capture is a deliberate test-only retained closure,
so this run supplies no heap or memory-retention evidence. Check no premature
completion, failure, stalled clock or post-close public event. Release the
capture on exit. Check public texture frames resume and no late frame after close.

Native timeouts: progress 5 s, further 200 ms progress 3 s, EOF 10 s; each test
has a 90 s XCTest watchdog. Settle callbacks 150 ms before assertions. Do not
relax gates to obtain a pass. Preserve initial failures and document whether
they are instrumentation defects or production defects. Keep raw XCTest
summary/tests/attachments and source/fixture/binary hashes with the result.

This does not prove acoustic output, long-stream replay, arbitrary codecs,
live streams, iOS behavior, automatic production EOF stop safety, statistical
latency improvement, or a whole-process memory bound. Existing synchronous
legacy stop latency still prevents simply adding production MainActor stop.
