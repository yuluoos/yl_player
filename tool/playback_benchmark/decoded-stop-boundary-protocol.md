# Decoded player-stop boundary intervention

Continue the approved callback-wrapper investigation on the existing feature
branch. Two serial independent processes on one frozen build and decoded-60.mkv
(60.229s AVC/AAC, 2813 AAC packets): legacy transparent hold, then legacy
transparent stop. Only test code drives the intervention; production is unchanged.

Both run to natural EOF, pause, and capture configured/drained heaps. After the
drained ACK, both wait at least2s. Hold leaves the graph paused; stop calls only
AVAudioPlayerNode.stop() on the unique existing player. No reset, engine stop,
disconnect, detach or host.close before the intervened heap. Retain the original
attached-node set and require it unchanged and engine still running at intervened.
Record mode, stop-call count, attachment count and unique player attachment at
all six phases: configured/completed/drained/intervened/disposed/disposedLater.
Only configured/drained/intervened/disposed collect heaps. After intervened ACK,
close the Host normally; verify detached player, stopped engine, zero ledger and
unchanged submissions immediately and >=2s later.

Keep transparent callbacks unobserved/null. Require legacy playedBack submissions
only, 2813 in formal60s runs, single firstFrame/completed, no failures, owned0 and
pendingfalse from completion onward. Modes/public event counters must stay stable
after EOF. Use existing 5s recorder settle, 30s ACK, 8s heap, 180s native and240s
parent deadlines. Natural EOF remains length+10s. Do not sample during playback.
Default short native regression exercises both hold/stop alongside existing cases.

Validate source/binary/fixture equality, distinct PIDs, non-overlapping uptime
windows, all heap hashes/lengths/PIDs/full tables and summaries. Compare intervened
minus drained in each process, then stop minus hold, for total heap and named
types. Missing types remain null. A disappearance from a table is not zero live
objects or a precise native retaining-owner graph. One sample per arm and the
unavoidable heap/ACK delays preclude exact costs/statistical claims. Stop then
close only locates release relative to this intervention; it does not separate
engine stop, disconnect and detach if release occurs later. No candidate enable,
production admission, global bound, minimum-OS or physical-output claim.
