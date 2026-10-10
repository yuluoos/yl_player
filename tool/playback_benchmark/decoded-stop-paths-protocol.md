# Same-build default/candidate stop latency

Follow up03f0744: default transparent stop took12.145656s on one60s file.
Do not compare candidate on a new build against that historical latency.
Use two serial independent processes of one frozen build and decoded-60.mkv:
legacy transparent stop, then candidate transparent stop. Both wait>=2s after
drained ACK, call only the unique native player.stop, then capture intervened
before normal host close. Keep four attached nodes/engine running until that
intervention snapshot. Same retained test graph references in both arms.

Existing six phases and four heap checkpoints, segmented uptime timestamps and
null/unobserved native callback counts remain. Require2813 submissions each:
legacy2813 playedBack, candidate2812 rendered plus one playedBack. Candidate
submission anchor must remain active through intervened and no fallback/failure
may occur. Close immediately and>=2s later: engine stopped/player detached,
ledger0, submissions/public events unchanged. Native short regression also
exercises candidate stop, without adding production hooks or new test methods.

Preserve8s heap/5s recorder settle/30s ACK/180s native/240s parent and length+10s
naturalEOF gates. No latency threshold selected after observing measurements;
report actual action segments, type counts and whole-process heap differences.
One sample per arm does not prove statistical benefit or an upper bound.
This pair compares stop paths, not long-wait coverage (that is historical).
Validate exact arm/profile pairing, same frozen identity, distinct PIDs/serial
windows and all raw heap bytes/hash/PID/full tables. If an external heap timeout
occurs, preserve the failed attempt and stop the batch; at most one unchanged-
identity complete repeat, never relax limits or retry until green.

No candidate production enablement, global bound, physical-output/device/OS
matrix claim. This does not validate automatic EOF stop, same-session replay,
seek or moving AVFAudio work between threads. Missing heap types remain null.
