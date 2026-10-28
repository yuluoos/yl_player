# P04 owned live network and repeated acceptance

Python 3.11+; no new runtime dependency in the player. Use the existing owned
MediaMTX/FFmpeg source workflow in `tool/rtmp_acceptance/README.md` for RTMP.
An owned HLS server and a continuous HTTP-FLV server can use the same relay.
Verify the source fixture hash and keep the publisher configuration/logs. The
relay's `--media-hash` is explicitly a declaration: a transparent relay cannot
verify decoded programme identity. It does not certify the publisher.

## Start a fresh relay for each trial

```
python3 -B tool/playback_network/live_relay.py \
  --protocol rtmp --upstream-port 19350 --port 18780 \
  --profile down-and-recover-v1 --run-id live-rtmp-cold-1 \
  --media-hash ACTUAL_OWNED_SOURCE_SHA256 \
  --log /tmp/live-rtmp-cold-1.connections.jsonl \
  --receipt /tmp/live-rtmp-cold-1.receipt.json
```

Use `--protocol hls` or `flv` and the corresponding owned upstream port. The
listener and upstream are both fixed to 127.0.0.1. Relative HLS playlist/segment
URLs must continue to use the relay origin; absolute URLs pointing directly at
the publisher bypass shaping and are not valid controlled-network evidence.
Do not use a source with redirects to an unshaped origin.

The startup JSON includes the actual port, profile ID/hash and run identity.
First client payload bytes arm one shared monotonic timeline. TCP health checks
alone do not arm it. Reconnects do not reset it. RTMP/HTTP protocol headers and
media bytes share downstream bandwidth; upload is backpressured but unshaped.
`latencyMs` is one application delay before upstream connect, not packet RTT.
Stalls save no burst credit; disconnect phases terminate even idle readers.
There are at most eight concurrent and 10000 admitted connections, a 120-second
connection deadline, 1024-byte forwarding chunks and bounded stream buffers.
The relay never logs payloads, URLs, credentials or exception text. SIGINT/SIGTERM
close only its listener/connections and write the final receipt. Startup output
is not a final cleanup receipt. Missing/truncated receipts fail validation.

## Capture public player behavior

Run from `packages/yl_player/example`, replacing the hashes/target:

```
flutter test --no-pub integration_test/live_mode_switch_test.dart -d macos \
  --dart-define=YL_LIVE_RUN=live-rtmp-cold-1 \
  --dart-define=YL_LIVE_PROTOCOL=rtmp \
  --dart-define=YL_LIVE_URL=rtmp://127.0.0.1:18780/live/owned \
  --dart-define=YL_LIVE_OWNED=true \
  --dart-define=YL_LIVE_MEDIA_SHA256=ACTUAL_OWNED_SOURCE_SHA256 \
  --dart-define=YL_LIVE_PROFILE=down-and-recover-v1 \
  --dart-define=YL_LIVE_PROFILE_SHA256=PROFILE_HASH_FROM_STARTUP
```

For HLS use a `.m3u8` URL; for FLV use a `.flv` URL. Device-local forwarding is
owned by the measurement operator. Save the actual process exit and full stdout.
The schema 2 collector records session, stage, monotonic time, revision and two
mode-command durations. Three 12-second observation windows cross the 25-second
recovery point. It also checks pause intent, rapid ordered switching and stale
commands after stop. Failed/timeout/cleanup outcomes remain in the result.
This is public state evidence; independent video/audio output and source-clock
measurement remain separate. `liveOffsetUs` is never labeled end-to-end latency.

Stop the relay after the player exits and summarize:

```
python3 -B tool/playback_network/summarize_live.py \
  --capture /tmp/live-rtmp-cold-1.capture.log \
  --connections /tmp/live-rtmp-cold-1.connections.jsonl \
  --receipt /tmp/live-rtmp-cold-1.receipt.json \
  --exit-code ACTUAL_PLAYER_EXIT_CODE --output /tmp/live-rtmp-cold-1.summary.json
```

Exit 0 means complete public mode observations and complete same-run trace;
exit 1 retains an unsuccessful capture; exit 2 means invalid/mixed evidence.
This is not CAP acceptance. Unknown counters, resets and absent physical/source
clock evidence remain unavailable. Phase byte counts are successful writes by
completion phase and do not prove client consumption or fairness.

## Repeated measurements and explicit targets

Use the conditions schema from [experiment-protocol.md](experiment-protocol.md).
One live experiment binds the same source and network profile across all three
protocols and two independent modes. Each fresh relay/session is assigned one
`baselineMode`: `smoothPlayback` or `lowLatency`. Run
`live_mode_baseline_test.dart` instead of the switch entry and additionally pass
`--dart-define=YL_LIVE_BASELINE_MODE=MODE_FROM_TRIAL`. The load buffer strategy
sets the requested mode before playback; it stays unchanged through a 36-second
observation window and the entire profile. Transaction captures remain separate
and are rejected as baseline input. Use separate experiments for different
sources, builds or network conditions. Never relabel cold/warm without applying
and documenting the corresponding cache treatment.

```
python3 -B tool/playback_network/aggregate_live.py plan \
  --conditions /tmp/live/conditions.json --id live --attempts 5 \
  --cache-state cold --cache-state warm --output /tmp/live/experiment.json
```

Fill each row's actual `exitCode` and three `artifacts`: `capture`, `connections`,
`receipt`. Each artifact has a relative `path` and its exact `sha256`, as for the
ABR archive. Bounded no-follow reads refuse symlinks, traversal and nonregular
files. All planned trials remain in the denominator, including absent, failed,
timeout, invalid and policy-violating trials. All network phases must have writes
before a run enters descriptive statistics. `down-and-recover-v1` is the current
repeatable comparison profile; zero-throughput fault profiles are diagnostic
runs and need different phase acceptance criteria before SLO comparison.

```
python3 -B tool/playback_network/aggregate_live.py summarize \
  --experiment /tmp/live/experiment.json --output /tmp/live/report.json
```

Metrics are per protocol/mode/cache p50/p95, with observed/unavailable counts. Mode-switch durations remain available only in the separate transaction
summary. Native rebuffer/reconnect deltas require monotonic, complete samples. Maximum
managed buffer requires every baseline sample to provide telemetry; otherwise
it is unavailable. It remains a sampled observation, not proof of a byte bound.

After a complete baseline, provide one explicit limits row per cohort, for
example (illustrative shape only; 123456 is **not** a recommended target):

```
[{"mode":"hls-smoothPlayback","cacheState":"cold","minimumSamples":5,
  "maxima":{"maximumManagedBufferedUs":123456}}]
```

Include every protocol/mode/cache cohort, not just the fastest protocol. ABR uses `auto`, `caps`,
`fixed` mode keys and its existing metric names. Freezing refuses incomplete
baselines and metrics that were unavailable. Values come from P08's agreed
measurement targets; do not infer product limits from tool defaults.

```
python3 -B tool/playback_network/evaluate_targets.py freeze \
  --experiment /tmp/live/experiment.json --limits /tmp/live/limits.json \
  --output /tmp/live/targets.json
python3 -B tool/playback_network/evaluate_targets.py compare \
  --experiment /tmp/live-candidate/experiment.json --targets /tmp/live/targets.json \
  --output /tmp/live-candidate/comparison.json
```

The target binds the canonical baseline manifest hash and conditions. Comparison
allows source/build artifact changes but requires identical device, OS, platform,
architecture, device kind, build mode, dependencies, media and network identity.
Every comparison recomputes the raw archive, not a cached summary. Failed trials,
insufficient samples or unknown metrics cannot pass. Target files are unsigned;
retain the frozen version before optimizing. Passing numerical checks does not
verify declared device/media provenance, physical output or complete CAP-LIVE.
