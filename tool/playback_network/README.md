# Reproducible HTTP network profiles

The Apple recovery probe also records cumulative `textureClears` (new captures)
and reports `replacementBoundaries` from actual published buffers on either side
of an item generation change. A held texture is not a new frame. The publication
gap and media-position delta are distinct; zero clears does not prove continuous
playback or audio synchronization. Older frame files remain readable with
`textureClears: null` in the boundary summary; missing observations are not zero.
`generationsWithoutPublishedFrame` retains generations with no observed output.
Recovery attribution uses installation completion (`elapsedAfter`) when available,
not the start of asynchronous preparation. The high-width observation in the main
row summary is AVPlayerItem geometry; use the frame file for actual buffer evidence.

For an explicitly paired physical iPhone, the native diagnostic collector supports
`--physical-device UDID --owned-host RFC1918_IPV4` instead of `--device SIMULATOR_UUID`.
Build the test host and test bundle with development signing first (the example's
test target normally disables signing; use `CODE_SIGNING_ALLOWED=YES` for this
device build). The phone must permit local networking and reach the selected Mac
interface. The listener binds only that explicit canonical private IPv4 address;
wildcard, public, link-local, hostname and implicit LAN binding are rejected.
The standalone server CLI and all non-device probes still bind loopback only.
The native probe also checks the explicit host, port, path and capture token.

Device observations are exported from this test app's random temporary directory
with `devicectl`. Collection copies only the bounded allowlist of observation
files. Cleanup checks the token, device kind, PID and full executable path before
termination; an unverified cleanup makes the receipt fail. A successful device
receipt proves collection and validation, not screen output, audio synchronization,
or CAP-ABR acceptance. Keep failed signing, installation and capture attempts.

P04 Task 1A tool slice. Python standard library only; no native build or player
process required. Serves an owned two-rendition AVC/AAC fixture after checking
every `SHA256SUMS` entry, and freezes those bytes in memory. The source has two
four-second Periods (320×180 / 350 kbit/s and 640×360 / 700 kbit/s), with AAC-LC.
The preparer repeats these ten Periods for a 40-second programme, preserving
media bytes and assigning each Period unique URLs to avoid reusing cached media.
Encoder/MPD bandwidth declarations are not observed transfer rates.

For EOF/prebuffer recovery diagnostics only, `prepare_fixture.py --duration-seconds
120 --output NEW_DIRECTORY` generates 30 Periods with a distinct manifest/inventory
identity. Pass `--dart-define=YL_ABR_PROGRAMME_SECONDS=120` to the public capture.
The default remains the byte-identical 40-second programme. Keep durations in
separate experiments; a longer diagnostic cannot replace a frozen baseline or
turn an earlier missing upshift into a pass. See the [capture protocol](capture-protocol.md).

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
as continuous media playback. Owned continuous HLS/HTTP-FLV sources are provided by `live_fixture.py`;
RTMP fault injection uses `tool/rtmp_acceptance`. The static HTTP server serves DASH;
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


## Owned continuous HLS / HTTP-FLV

`live_fixture.py` uses FFmpeg to loop the repository-owned AVC/AAC source with
continuous output timestamps. It verifies the pinned source SHA-256 before
starting any process and serves only allowlisted loopback paths. It supports the
same application bandwidth/stall/disconnect profiles. The profile begins at the
first valid GET, so app build time does not consume it. No profile means no
intentional network impairment. RTMP continues to use `tool/rtmp_acceptance/run.py`.

```sh
python3 -B tool/playback_network/live_fixture.py \
  --protocol flv --run-id live-flv-001 \
  --output /private/tmp/live-flv-001 \
  --profile stall-and-recover-v1
```

Use `--protocol hls` for a moving six-segment playlist. Pass the startup URL,
`sourceSha256` and run ID to `live_mode_switch_test.dart` as documented in the
[capture protocol](capture-protocol.md). Use a new output directory for every run.
For Android, explicitly reverse the printed port on the selected test device,
then remove that mapping after the run. Do not run different native platforms or
builds concurrently when collecting comparable timing samples.

The process exits on Ctrl-C/SIGTERM or after 300 seconds. Cleanup interrupts
blocked sockets and shaping, terminates only its own FFmpeg children, joins
handlers, then writes `receipt.json` with hashes, request bytes/times and cleanup
status. Bounds are eight simultaneous connections, 10,000 lifetime connections,
32 lifetime FLV publishers, 8 KiB transfer chunks and two-second socket writes.
HLS files roll forward; FLV connections each start a fresh timestamp epoch.
Source identity and generated timestamps do not establish a synchronized
source-to-display clock. End-to-end latency and physical output remain unverified.

## Apple ABR access-log diagnosis

The explicit native observation entry
`YlDashResourceLoaderTests.testActualOwnedDashAdaptiveObservation` uses the real
DASH projection/proxy and AVPlayer backend with an injected player for read-only
access-log inspection. It is dormant without `YL_ABR_PROBE_URL` and
`YL_ABR_PROBE_DIRECTORY`. The collector owns its loopback server and freezes the
built application files before/after the run:

```sh
python3 -B tool/playback_network/abr_accesslog.py \
  --products /absolute/path/to/built/Build/Products \
  --directory /private/tmp/new-abr-accesslog-run \
  --device IOS_SIMULATOR_UUID
```

Omit `--device` for arm64 macOS. Build the current example native tests first;
selecting a nonexistent method or stale binary cannot pass without complete
observation rows. The normal profile is unchanged. An explicitly supplied
`--profiles` file and `--profile` may define a separately identified diagnostic
intervention; it must not replace the frozen baseline.

`--duration-seconds 120` selects the separate longer diagnostic. The optional
`--direct-hls-control` uses AVPlayer directly with independently generated HTTP
HLS playlists referencing the same media and MPD segment timelines. It bypasses
the project's DASH loader/proxy/backend and is never production-path acceptance.
Its master declares the same 414000/764000 aggregate rates, resolutions and
codecs; media bytes are unchanged, and its extra playlists have their own frozen
inventory identity. The managed probe keeps its preparation-before-AVPlayer
initialization order. A previously built host must confirm transport and duration
in every native row, or the collector rejects the attempt.

For an explicitly labeled timing intervention, `--startup-delay-ms 1000` waits
after managed preparation. Direct mode first GETs the owned MPD to arm the same
server clock, then waits before starting AVPlayer. Only 0..2000 ms is accepted;
default zero preserves normal startup. The native rows and receipt bind the delay.
Compare the actual segment start times at the 10-second boundary, not just the
CLI delay, since launch/decoder/scheduling timing still varies. Never silently
use a delayed run in place of a frozen baseline or infer causality from unmatched
weak-phase entry states.

`--recovery-action seek-current` or `--recovery-action reload-source` is an
explicit managed-only 120-second experiment. After 35 seconds, and only after
high-to-low output with a recorded CoreMedia -12889 error while still low, the
probe performs one exact seek to the current position or prepares the same source
and invokes the existing `replaceActiveDash` transaction. This fixture-specific
trigger is not a production recovery policy or a public penalty-box API.
The pre-operation record is written before awaiting work; the final attempt
records time, position, completion and whether the item changed. Reload completion
means installation returned, not seek landing or seamless output. Error/access
log counters restart with a new item; preceding rows remain intact. Sampling
pauses during the operation, so gaps cannot measure black-screen duration.
The collector binds the action to every row and rejects missing/failed attempts.
Intervened rows cannot be summarized without an explicit expected action.
`highOutputAfterInterventionObserved` refers only to the owned 640-pixel fixture;
neither this observation nor a successful capture admits CAP-ABR. Default `none`
keeps the original no-intervention behavior. Direct HLS and 40-second intervention
requests are rejected rather than silently changing the experiment.

`--recovery-action auto-reload` evaluates an experimental policy in the test
host, not in the production backend. It is limited to the owned clear static
DASH fixture, unconstrained auto playback. It requires previous high output,
current low output, download-overdue history, at least 5 seconds continuously
buffered from the current position (future ranges across gaps do not count) and
20 seconds remaining, plus two consecutive 8-second windows with at least three
new requests and transfer-byte/time deltas above 1.25 times the declared high
rate. These are candidate decision parameters, not new acceptance thresholds or
proof of available network capacity. The policy has no private penalty-box API.

The source budget is two reservations, with 500/1000 ms backoff; cancellation,
failure, successful frames and new item generations never refund it. Preparation
rechecks ticket age, generation, item identity and current eligibility before
installation. `--auto-scenario pause-first` explicitly pauses after the first
ticket is issued and resumes two seconds later, exercising cancellation and
retained budget. It is separately identified in every row and the receipt.
The scenario explicitly invalidates the ticket on pause, so an early resume
cannot revive it. A production dispatcher would have to connect this invalidation
to every relevant intent change; that integration is not present here.
Broader seek/constraint/DRM/network races still need production qualification;
the host has no automatic-recovery product hook.

Frame sampling version 2 uses an independent approximately 16 ms main-actor
pump during asynchronous preparation. `frame-samples.jsonl` records actual
published buffers, item generations, player position/rate and pump timing.
The old duplicate raster read is removed; the display callback consumes its
retained buffer. The collector checks sample ordering and frame totals, and
reports maximum publication/pump gaps without asserting continuity or audio
synchronization. Main-thread blocking can still prevent sampling; these are
application publication observations, not physical screen/audio measurements.
Old 250 ms capture files remain historical evidence and do not meet this host
identity contract. Failed/no-op automatic runs do not invent a recovery.

Logs contain playback/geometry/bitrate/transfer counters, buffer ranges/flags,
`downloadOverdue`, and the most recent 32 error-log events (total count retained).
Error comments are bounded and URL-redacted; access-log URLs and server addresses
are not recorded. A profile-identity-checked HEAD brackets the server clock after
the first geometry appears. Earlier rows have no clock alignment.
The test discards published test pixel
buffers every poll. The output records actual down/up geometry changes and
AVPlayer's reported bitrate; it does not reveal the private ABR decision
algorithm, establish a recovery deadline, or certify CAP-ABR/physical output.
`observedBitrate` is an empirical downloaded-media metric, not instantaneous
recovery capacity; negative `indicatedBitrate` means unknown, not proof that a
variant was excluded. Native completion requires the declared programme end
(within 0.5 s), disposal and matching transport/duration/delay. Full public
Flutter auto/caps/fixed acceptance remains a separate entry.

Once the fresh output directory is created, setup failures (including missing
products, invalid test manifests and missing host metadata) also leave a failed
`receipt.json`. They are part of the attempt history, not omitted trials.
Executable identity compares resolved paths so `/tmp` and `/private/tmp` aliases
identify the same host. Cleanup still requires the exact captured PID, start
time and process identity; a different executable path is rejected. An absent
or unverified launched host never becomes a successful cleanup claim.
