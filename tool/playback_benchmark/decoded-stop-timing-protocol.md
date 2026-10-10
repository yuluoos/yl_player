# Segmented stop timing and longer wait-only control

Follow-up to2f9b63f: previous hold/stop drained-to-intervened intervals4.998/18.620s
were unequal despite approximately2s explicit sleep. Do not assign residual
latency to stop without timestamps. Preserve that committed evidence unchanged.

Same frozen source/binary/decoded-60.mkv, serial independent legacy transparent
processes: hold30s after drained ACK, then stop after2s. The longer control is
fixed before measurement; no post-hoc deadline relaxation. Preserve the8s heap,
5s recorder settle,30s ACK,180s native and240s parent bounds. Natural EOF still
length+10s. All stop-boundary graph/EOF/ledger/public-event gates remain mandatory.
No production edits or candidate admission. Native short regression uses2s hold.

Record monotonic uptime at drained ACK return, sleep start/end, synchronous
intervention start/end (stop call only for stop; hold has no action), assertion
completion, intervened probe entry, recorder settled, memory read finished and
row capture. Before intervention timing is empty; afterwards it is immutable.
Keep callback counts unobserved/null. Validate all times finite and ordered,
wait duration consistent, action count consistent, row binding and post-close
identity. Report adjacent segment durations and their conserved total.

Compare both rows and actual heap-start observation windows, and the interval
from drained ACK return to intervened row. Require hold to cover stop for a
longer-wait-control conclusion; explicitly return coverage false if it does not.
Do not infer that an uncovered control isolated time effects. Report hold action
elapsed separately; native stop duration for hold is null, not zero.

Parse8 full heap tables with all existing hash/length/PID/table validations.
One process per arm remains exploratory; even a covered wait-only control is
not a precise native retainer graph, object-liveness proof, statistical benefit,
or global memory bound. No physical output/device/minimumOS/iOS claim.
