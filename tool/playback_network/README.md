# Reproducible HTTP network profiles

P04 Task 1A tool slice. Python standard library only; no native build or player
process required. Serves an owned two-rendition AVC/AAC fixture after checking
every `SHA256SUMS` entry, and freezes those bytes in memory. The source has two
four-second Periods (320×180 / 350 kbit/s and 640×360 / 700 kbit/s), with AAC-LC.
The preparer repeats these ten Periods for a 40-second programme, preserving
media bytes and assigning each Period unique URLs to avoid reusing cached media.
Encoder/MPD bandwidth declarations are not observed transfer rates.

From the repository root:

```sh
python3 -B -m unittest discover -s tool/playback_network -p 'test_*.py' -v
python3 -B tool/playback_network/prepare_fixture.py \
  --output /private/tmp/yl-network-owned-40s
python3 -B tool/playback_network/network_profile.py \
  --root /private/tmp/yl-network-owned-40s \
  --profile down-and-recover-v1 \
  --log /private/tmp/yl-network-new-run.jsonl
```

The fixture directory and log must not already exist. The preparer prints source,
generated manifest and inventory hashes; preserve that receipt. The server binds
**127.0.0.1 only**, by default
port 18779 (`--port 0` selects a free port). Startup prints the manifest URL,
canonical profile SHA-256 and asset count. Stop with Ctrl-C; the final stdout
record counts accepted/rejected connections and recorded GET/HEAD requests.
Save stdout alongside JSONL for a complete run. Restart the server for each run.
The timeline begins when the server is constructed, just before binding; times
in the trace share that monotonic origin, not the player's load/first-frame time.

For public-player runs use the opt-in `--start-on-first-get --run-id RUN_ID`
mode and [capture protocol](capture-protocol.md). That mode defers the origin
until the first GET of a known asset, so compiling the app cannot consume the
network profile. HEAD preflight exposes run/profile/asset hashes without arming.

## Semantics

`profiles.json` uses schemaVersion 1. Each named, versioned profile has ascending
steps, starting at `atMs: 0`. Times are milliseconds; `bytesPerSecond` is shared
response-body throughput across all connections. The last step persists.

- `down-and-recover-v1`: 500000 B/s → 50000 B/s at 10 s → 500000 B/s at 25 s.
- `stall-and-recover-v1`: no body throughput from 10 to 15 s, then recovery.
- `disconnect-and-recover-v1`: active transfers and new requests fail during
  10–12 s; requests after 12 s can succeed. There is no automatic client retry.

`latencyMs` adds one **application response delay per request**, sampled at that
request's start. It does not emulate packet RTT, TCP congestion, upload traffic,
DNS or TLS. Body shaping follows the global timeline even across segment/range
requests; reconnecting does not reset it. A zero rate stalls without saving
credit for a later burst. Disconnect steps also interrupt response delay.
HTTP response headers are unshaped. HTTP/1.0 closes each connection explicitly.
GET, HEAD and a single byte range (including suffix/open-ended) are supported;
multiple/invalid ranges return 416. Unknown paths return 404.

The shared limiter reserves each body chunk (at most 1024 bytes) before writing
it; timing is conservatively quantized to chunks. Scheduling oversleep is not
credited as throughput. A cancelled or disconnected partial reservation can
consume time without delivering bytes. This is an application fixture server,
not a packet-level network emulator or a guarantee of fair connection order.

## Trace and limits

Each completed handler writes a bounded JSONL record: request ID, profile/hash,
known asset/hash, GET/HEAD, attempted HTTP status, byte interval, monotonic start/end
and outcome. `bodyBytesWritten` counts only fully successful `sendall` writes;
it does **not** claim TCP ACKs, client receipt, decoded bytes or physical output.
A failed partial `sendall` may have transmitted uncounted bytes; its outcome is
`client_io_error`. Preserve incomplete/timeout/disconnect runs as failures.

Queries, headers, unknown paths, native exceptions and URLs are never logged.
Only allowlisted paths are logged. No proxy, external network fetch, arbitrary
directory listing or global host network change is provided.

Limits: 64 MiB total preloaded media, 4096 assets, 1 MiB inventory, eight active
connections, 10000 admitted connections/run, two-second socket I/O timeout and
120-second absolute connection and shaping deadlines. Shutdown interrupts open
sockets and wakes shaping waiters. A client's disconnect during a stall is only
observed at the next write or deadline, so this tool cannot measure prompt client
cancellation/cleanup latency. Excess admissions close immediately and
increment the shutdown summary counter without extending the request log.
Malformed HTTP or unsupported methods are not media GET/HEAD trace records;
the shutdown connection totals may therefore exceed recorded requests. A forced
process kill can lose final rows/summary; it is not a valid complete run.

## Evidence boundary / next baseline

Virtual-clock tests assert exact rate-boundary/stall/drop/recovery behavior;
loopback tests assert received bytes, range replies, partial-body disconnects,
shared bandwidth, bounded admission and safe logging. No player is involved.

The generated 40-second MPD has structural/hash validation. The missing-high
variant also has a macOS public-player run covering fixed selection across an
existing Period, missing-track fallback and caps/seek. Full-trajectory ABR and
three-platform acceptance remain open. Do not interpret repeated HTTP downloads
as continuous media playback. The original static HTTP server does not generate live sources;
protocol-transparent shaping is now provided by `live_relay.py` (see below). Real TCP RTT and end-to-end live latency remain
unavailable, as do P08-derived device SLOs until measured and frozen. This tool
does not establish CAP-ABR, CAP-LIVE, mode switching or three-platform acceptance.

Repeated measurements can be predeclared and summarized without a test environment
using [the offline experiment protocol](experiment-protocol.md). It groups results
by mode/cache state and preserves every planned, failed and timed-out attempt.

## P04 engineering completion (2026-10-20)

The HTTP trace now includes `phaseBoundariesMs` and `phaseBytesWritten`. A chunk
is counted in the phase in which its complete write returned. This is an
application write observation, not TCP receipt or a division of bytes by the
phases in which their rate reservations occurred. The sum equals
`bodyBytesWritten`; only known media assets enter the ABR phase totals.
`aggregate_experiment.py` now requires actual media writes in all three
`down-and-recover-v1` phases. Legacy captures still parse, but are ineligible for
weak-network aggregation when their phase evidence is unavailable. A transfer
ending after recovery alone is insufficient.

Generate a separate PD-01 programme with `prepare_fixture.py --missing-high-after 2`.
Its high AVC rendition exists for two full Periods (including different IDs),
and disappears at 8 seconds. Removed high media are not served. The independent
manifest/inventory hashes identify this scenario. Run
`integration_test/abr_fixed_period_test.dart` with the same `YL_ABR_*` identity
parameters as the ordinary capture. It checks fixed output in Period 2,
preparation failure rollback, missing-track fallback, return seek, and concurrent
caps/seek. It emits `YL_ABR_PERIOD_*` records; do not feed this intentional
fallback scenario to the ordinary fixed-weak-network validator.

For owned live upstreams, see [live protocol engineering](live-protocol.md).
The relay accepts HLS, HTTP-FLV and RTMP traffic on loopback without changing
protocol messages. Both single-run and repeated live validation are available.
`evaluate_targets.py` works with either ABR or live experiment manifests.
It recomputes hash-verified raw evidence before freezing explicitly supplied
p95 limits or comparing a candidate; it never supplies a device target itself.

All Python regressions are discovered by `tool/check_foundation.sh`, hence by
the quick/full foundation CI shards. Public Flutter integration entries require
an explicit owned source, identity and selected target. Offline unit tests and
independent FFmpeg decoding do not count as those device entries running.
