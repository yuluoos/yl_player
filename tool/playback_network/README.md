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

New native captures include `policySamplingVersion: 1`. Automatic runs preserve
`policy-decisions.jsonl` from the exact input used by each policy evaluation:
eligibility, buffer/remaining time, cumulative transfer counters, window bitrate,
rejection reason, reservations and backoff. The reader checks qualified-window
counter deltas and duration, eligibility, reservations and tickets; rejected inputs
may retain unknown/negative values without becoming eligible. The receipt validates this trace and
reports `policyObservation`. `triggerExercised` means a recovery ticket was issued;
it does not prove installation, successful upshift, continuity or acceptance.
Zero attempts is explicitly untriggered, even when the media reaches EOF.
Historical captures without the version remain readable; exact decisions cannot
be reconstructed retroactively from their less frequent main rows.

The XCTest action log records package-owned `[YL-ABR]` failure codes plus iOS
route/interruption/lifecycle notification types and numeric reasons, with probe
elapsed time. It does not log audio device names, credentials or source URLs and
does not resume playback in response to these notifications. Main rows retain
backend status/failure code alongside AVPlayer item status, which alone may stay
ready after the backend's stall watchdog fails the session.

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
to every relevant intent change. These legacy diagnostic scenarios explicitly
disable the production dispatcher, preserving their original experimental scope.
Broader seek/constraint/DRM/network races still need production qualification.

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

The macOS native publication tests depend on the real display clock. Record the
display awake/sleep condition when investigating missing frames. Keep the display
awake for foreground playback tests (for example, scope `caffeinate -u -d -i` to
the test command); retain any prior sleep-condition failures and use the same
binary and deadlines for the comparison. This is not background-playback acceptance.

`trailingNoPublicationMs` is the observed interval from the last sample containing
a published frame to the final frame-pump sample. It preserves terminal freezes
that inter-frame maxima cannot show; it is not a new stall threshold, physical
black-screen duration, or proof of output after capture ends. Valid frame
observations are retained even if playback/EOF validation fails; the receipt
continues to fail, and continuity/audio/physical acceptance remain false.

Debug native captures may include `proxySamplingVersion=1`, a numeric `proxy`
snapshot, and `sampleUptime` in the main rows. Admission/completion timestamps
use the device's monotonic uptime, not origin-server elapsed time. Counters are
scoped to the current loader and reset on item replacement; do not difference
them across generations. Completion counts include cancellation callbacks after
a local connection has already closed. They are not HTTP-success counts.
`activeTasks`, `pendingSends` and `suspendedTasks` are sampled gauges of currently tracked records. A zero
sample cannot rule out work between samples or detached callbacks after closure. No URL, headers or resource IDs
are recorded by this snapshot. The observations do not alter proxy behavior.

Frame rows additionally record `itemStatus` and `resumeSeekPending` in these
builds. Their sampled transitions help bound exact-seek and first-buffer waits;
`readyToPlay` is not assumed to precede the first pixel buffer. They do not
measure decoder PTS, audible output, or justify bypassing the seek publication
gate. Preserve the original publication gap even when the previous texture is
retained, and compare diagnostic changes with the original built host when
investigating observer overhead.

`--candidate-preparation asset-metadata` is an owned, managed 120-second
`auto-reload` experiment. It loads `playable`, `tracks` and `duration` on the
candidate asset while the current item remains installed. `playable` alone can
report loaded without reading resources and is not a preloading proof. The
default `manifest-only` retains the previous preparation path. Native rows must
echo the requested mode; an older host that ignores a nondefault mode fails
collection instead of being counted as a successful experiment.

Metadata preparation stops at the earlier of two seconds or the existing
ticket expiry. On abort it cancels asset loading and explicitly discards the
owned loader; calling `AVAsset.cancelLoading()` alone is not treated as proof
that loader requests ended. Installation still revalidates the original ticket
and current item, preserves the exact seek and does not refund reserved budget.
Events distinguish manifest completion, warmup timestamps/outcome, current-item
identity, frame/position progress and candidate proxy snapshots. Metadata loaded
is not decoder preroll, first-frame availability, safe production integration,
or seamless output acceptance. Normal and warmed trials must remain separately
labelled, including failures and cancelled candidates.

On iOS, an `audioRoute` signal with `reason=2` is an old-device-unavailable
notification. AVPlayer may pause for this privacy event even with buffered data.
The backend now mirrors it into paused transport intent and waits for explicit
play; reconnecting a route never authorizes automatic resume. Keep the native
signal and proxy snapshots together when diagnosing a terminal pause. A capture
that does not reach EOF still fails collection: a correctly handled system pause
is not an ABR or continuity pass. Do not attribute earlier buffered-exhaustion
failures to route loss without their own event evidence. Synthetic route-notice
regressions on a physical device are distinct from physical unplug/disconnect
validation.

`--candidate-preparation asset-preroll` adds a bounded owned-media experiment:
create a muted, paused candidate player, wait for player/item readiness, seek
exactly, then preroll at rate 1. It checks the original ticket and playback
intent throughout, with the earlier of a two-second limit or ticket expiry.
Aborts cancel seeks/prerolls/asset loading, detach the item and discard its loader.

A prerolled item must never be transferred between players. The physical-device
prototype raised an AVPlayerItem association exception even after detaching it.
The retained experiment instead creates a **fresh item from the warmed asset**;
normal exact resume seek is still required and decoder state is not transferred.
Capture validation rejects installations without explicit completed preparation,
old-item retention, candidate detachment, fresh-item adoption and non-reuse proof.
This is opt-in diagnostic tooling, not production automatic recovery or latency
acceptance. Failed preparation still spends its reserved attempt.

`--auto-scenario pause-during-preparation` requires `asset-preroll` and invalidates
the first ticket after actual candidate readiness, before its seek. The event
records whether this point was reached. Resume after the diagnostic pause cannot
revive that ticket; a second reservation uses the original longer backoff. This
one injection does not cover every seek/preroll/credential/constraint race, and
an unexercised injection must remain unverified.

Metadata preparation also revalidates the original ticket before loading,
throughout polling and before returning success. Revocation cancels the asset
and its owned loader requests instead of waiting for the two-second deadline.
`--auto-scenario pause-during-metadata` requires `asset-metadata`; it pauses and
invalidates the first ticket after issuing the metadata loading operation.
This injection alone does not prove a network request had already arrived;
separate native tests hold actual resource-loader requests and verify cancellation.

`--auto-scenario seek-during-preparation` requires `asset-preroll`; after actual
candidate readiness it invalidates the first ticket and asks the existing backend
to seek forward one second. Events record successful invocation and the target.
The real frame trace must still be inspected for the landing and old-item retention.
Neither scenario changes budgets, backoff, exact seek or capability acceptance.
Native local-media tests separately cancel after seek and preroll calls are issued;
these cover operation boundaries, not every asynchronous race or physical output.

Automatic recovery eligibility now requires an unconstrained peak bitrate,
zero preferred maximum resolution and no fixed video selection. Width-only,
height-only and fixed-selection policies must not reserve recovery attempts even
when the sampled bandwidth and buffer conditions otherwise qualify.

`--auto-scenario caps-during-preparation` and `fixed-during-preparation` require
`asset-preroll`. Once the first candidate becomes ready, the diagnostic invalidates
its ticket and commits a separately prepared width-320 cap or fixed low track
through the existing backend replacement path. Both candidates use the same
manifest snapshot. The event records actual success and item replacement; rows
record maximum resolution, fixed track ID and unconstrained-policy eligibility.
Inspect all later rows and frames for preserved selection and compliant output.
A new generation in these scenarios comes from the injected user policy, not an
automatic recovery success. This is backend-path coverage, not the full public
host auto/caps/fixed matrix or physical continuity acceptance.

### Typed public-host policy cycle

`abr_accesslog.py --public-policy-cycle --duration-seconds 120` runs the existing
owned capture through `YlApplePlayerHost.load`, `setVideoConstraints`, and
`selectVideoTrack`: initial auto, 320-width cap at 8 seconds, clear at 24 seconds,
fixed low track at 50 seconds, and auto at 70 seconds. It requires managed DASH,
no diagnostic recovery, no preparation experiment, and no startup delay. The
frozen network profile, media duration, and capture deadlines stay unchanged.

`public-policy-events.json` records each command and actual item/session change.
The receipt requires all five ordered phases in the same session, accepted
constraints/selection, at least three samples and three new-frame submissions
per phase, only 320-wide new frames while capped/fixed, and a 640-wide new frame
in each unrestricted phase. Missing commands, failed application, host failures,
or missing frame evidence reject the run even if EOF was reached. The usual
full frame-gap evidence is retained. This native typed-host matrix does not
exercise the Dart messenger, automatic recovery competition, physical screen,
or audio/subtitle continuity; it never marks capability acceptance.

### Public-host preparation race (diagnostic)

`--public-policy-race` uses the typed public host for both loading and the policy
command. It requires `--duration-seconds 120 --recovery-action auto-reload
--candidate-preparation asset-preroll` with `--auto-scenario
caps-during-preparation` or `fixed-during-preparation`; it cannot be combined with
`--public-policy-cycle`, direct HLS, or startup delay.

The frozen policy must naturally issue one ticket. After the candidate reaches
real AVPlayer readiness, the test awaits `setVideoConstraints` or
`selectVideoTrack`. It does not manually invalidate the ticket: current host
policy and item identity must reject the old candidate. No public-host recovery
installation path is added. The collector requires a successful command in the
same session, changed active item, cancellation and cleanup of the old candidate,
retained source budget, sustained accepted policy, and only 320-wide new frames
following command completion. It also retains the existing policy-window,
frame, and EOF checks. Zero tickets fail race acceptance, even if playback ends.

This is a diagnostic public command race, not a production automatic recovery or
physical audiovisual continuity acceptance. Original-profile runs that never
exercise a ticket remain failures for this race and retain their decision logs.

The candidate deadline is monitored while the public command waits. Candidate
cleanup records are fixed before joining the independent command task; expiry
does not cancel the user command. Race acceptance additionally requires command
completion and candidate cleanup within the original preparation/ticket deadline.

### Public pause/seek preparation races

`--public-policy-race` also accepts `pause-during-preparation` and
`seek-during-preparation` with the same 120s/auto-reload/asset-preroll requirements.
The diagnostic ticket now captures the host's acknowledged transport revision,
read from the coordinator's existing restoration-intent counter. A successful
pause or seek invalidates old authority even when the AVPlayer item is unchanged;
failed admission does not change this counter. This is an internal read-only
view, not a Pigeon API or an enabled production recovery policy.

Pause holds for two seconds and requires stable position, paused state, zero rate
and false playback intent before an explicit public `play`. Seek moves forward
1000ms and requires subsequent published-buffer presentation times at or beyond
the target (the existing 50ms tolerance). The test-only video-output factory
records AVPlayerItemVideoOutput `itemTimeForDisplay`, associates it with each
actually published buffer, and emits `framePresentationTimes`; player clock
position alone is insufficient. Missing, stale or mismatched timestamp counts
fail validation. Both paths
require new frames/progress after the command, original preparation deadlines,
retained same-source attempt budget, later 640-wide output, and no stale candidate
installation. Main and policy samples must have monotonic UInt64 intent revisions;
every event ticket binds to its issuing decision, and command-before/after
revisions must match both streams. A revision change resets qualification
windows and pending authority without refunding attempts. Later
naturally reserved tickets remain subject to the original two-attempt budget;
this diagnostic does not install public-host recovery candidates. Credential,
physical-output and full production recovery acceptance remain separate.


### Recovery credential provenance

Policy sampling version 2 adds `credentialRevision` alongside transport intent.
It is the count of distinct resources permanently stripped within the same user
Load; repeated stripping is idempotent. It contains no URLs or credential values.
Recovery preparation shares the active HLS loader's credential context and request
metadata. A change resets qualification windows and revokes pending/in-flight
authority without refunding the source attempt budget. Every candidate event binds
both ticket revisions to its issuing decision. V2 rejects missing or mismatched
authority; historical V1 remains separately identifiable, without upgrading its
coverage. No production automatic recovery is enabled by this diagnostic policy.

Local contracts combine actual AVPlayer candidate readiness with an owned
cross-origin redirect/return request, and verify candidate cancellation, resource
release and credential stripping through a separately prepared shared-context
proxy. Synthetic bandwidth samples issue the test ticket. This is not a full
public/Dart credential race, physical playback continuity or high-tier recovery
acceptance; those remain separate pending checks.

The final diagnostic installation is synchronous under the same context lock as
`strip`, after both DASH loaders finish preflight. It never waits for network or
reenters the context; background changes order before the fence (reject) or after
actual item installation. V2 installed events require `credentialCommitAccepted`.
This fence is exercised through actual backend item replacement, independently
of the local readiness/redirect test; it does not enable production recovery.

## Production iOS recovery capture

Add `--production-recovery` to the physical-device, 120-second `auto-reload`,
`normal`, `manifest-only` capture. This selects the typed public host with the
production dispatcher enabled; the probe never installs a diagnostic candidate.
Native production decisions and completed events share the existing strict
policy/authority validation. Actual buffers must show high output after a real
downshift and after any successful installation; EOF and final high output are
required. System interruption signals invalidate this controlled capture.

For runs intended to exercise an actual same-session automatic installation, add
`--require-production-install`. This only tightens the receipt: natural recovery
or cancelled-only events fail, without changing the native player, network profile,
or policy thresholds. It requires `--production-recovery` and is incompatible
with `load-prepared`, whose existing cancellation/new-session budget checks apply.
The receipt records `productionInstallRequired`; the default remains observation
without a required installation so historical natural-ABR controls stay distinct.

`--production-command pause-resume` sends a public Pause after reservation one,
waits two seconds, then sends public Play. It requires multiple native paused
samples with no position drift beyond 50 ms, no early install, no budget refund,
and a real installation using reservation two and its 1000 ms backoff. This is a
separate scenario, not a replacement for an unmodified original-profile run.
Host proxy boundaries and resume-seek gates are recorded alongside actual frames.
All receipts remain diagnostic evidence; production-path coverage does not by
itself certify CAP-ABR, physical continuity or audio synchronization.

生产候选提交前竞争可使用 `--production-recovery --production-command pause-prepared|seek-prepared|load-prepared`，仍限定真机、120秒、normal/auto-reload/manifest-only。内部默认nil钩子仅在真实候选准备完成后暂挂；公开命令负责取消，采集器不直接取消生产控制器、不改带宽或截止。第一候选必须在2秒准备期限内被取消且没有安装；暂停/跳转后必须消耗第二次预算并真实恢复高档。暂停需至少2秒、3个静止样本；跳转与新Load的首个实际帧PTS必须位于目标前后50ms内，后续帧不能落回目标之前50ms以外；首帧延迟单独报告，不据此授予物理连续性验收。

新Load使用相同请求标签但必须产生新会话，旧候选取消和新预算分别审计，公开Load返回时新预算必须已归零；其高档帧属于新Load，不能宣称同会话自动恢复。`production-command-events.json`、按会话标识的策略决策和原始帧共同核验边界。所有受控通过仍不代表物理音画连续性或跨设备稳定性通过。

## Read-only bandwidth diagnosis

For a completed owned-fixture capture with exact policy decisions:

```sh
python3 -B tool/playback_network/bandwidth_diagnostics.py CAPTURE_DIRECTORY \
  --profiles PROFILE_DOCUMENT.json > NEW_DIAGNOSTIC.json
```

This checks profile identity and request accounting, reuses the strict policy
validator, and reports each phase's server write bytes, summed request durations,
and the union of overlapping request intervals separately. A request crossing a
phase boundary, failed/empty responses, and HEAD preflight remain counted in the
excluded totals; they are not silently treated as successful phase samples.
The configured ceiling and nominal request latency sum are configuration values,
not measurements of link capacity or actual latency. Neither server goodput nor
its interval union replaces the AVPlayer policy's bandwidth observation. The
server and device clocks are not subtracted or assumed synchronized. The report
cannot approve recovery, continuity, or capability acceptance, and never modifies
raw captures or the original collector receipt.

For causal comparisons, keep the original profile frozen and change one factor
in a separately named diagnostic profile. Existing stall/headroom/zero-latency
contrasts change several factors and do not isolate request delay alone.

New DEBUG native probes explicitly enable `proxyRequestSamplingVersion: 1` and
write `proxy-requests.jsonl` (bounded to 10000 records / 16 MiB). Production and
ordinary debug sessions leave the observer disabled. One terminal record per
admitted request uses a random proxy identifier and numeric task/server request
IDs; URLs, credentials and arbitrary header strings are excluded. The fixture's
`X-Yl-Request-Id` is metadata for correlation only and is not sent downstream.

The reader preserves cancelled/failed records, rejects inconsistent or duplicate
complete records, reports unmatched server media requests, and distinguishes
upstream callback duration from server write duration and loopback send waits.
All device boundaries use the same monotonic clock. Server intervals are compared
as durations, never by subtracting timestamps from device timestamps. Their
difference includes transport, scheduling and backpressure, not isolated RTT.
Send completion is Network.framework content processing, not remote receipt,
decoding, display, or audio synchronization; overlapping send waits remain sums.
Legacy captures without the version are identifiable and are not retroactively
claimed to include these boundaries.

Cancellation before response delivery may never expose the server response ID.
The opt-in trace therefore also sends a random UUID `X-Yl-Trace-Id`; the fixture
logs only a single syntactically valid UUID and the reader cross-checks both IDs
when present. This header is absent when tracing is disabled. Diagnostic capture
has a stop/registration fence and a bounded drain; a sealed event is not considered
delivered until its writer returns. Active trace ownership outlives transport task
removal, including chunk tails. A drain failure fails the native probe, and missing
request correlation adds an error to the collector receipt while retaining the
partial diagnostic. Neither condition can silently produce a successful capture.


### Date-state diagnostics and repeated-downshift budget proof

New DEBUG probes use proxy request sampling version 3, with nested metrics version
2 and `durationStates` for each duration: 0 observed, 1 missing start, 2 missing
end, 3 both missing, 4 invalid ordered/finite pair. No absolute dates, URL or
headers are recorded. Shared endpoint presence must agree. Historical v1/v2
reading remains; v3 cannot silently downgrade to old metrics. Missing durations
remain null and a successful request with any incomplete transaction still fails.
A response-less first connection close can produce two Foundation transactions;
this controlled reproduction does not identify the cause of every historical
multi-transaction failure.

`--require-budget-exhaustion` requires `--production-recovery`,
`--require-production-install` and `pause-resume` or `pause-prepared`. It requires
actual attempt-two installation, published high frames followed by new low frames
on that same item, and two consecutive eight-second counterfactual bandwidth
windows at the unchanged 955000bps/three-request/progress gates while native
policy reports `budgetExhausted`. No third reservation, source/intent/credential
reset or budget refund may satisfy it. These are independent proof windows, not
native window decisions (the budget guard executes before window qualification).
All original EOF/final-high, authority, transaction and continuity checks remain.
The budget observation may survive a later final-high failure; that receipt still
fails. This does not certify physical screen/audio continuity.

The collector also preserves `connection-lifecycle.json`: server-local elapsed
admission/handler-completion times, accepted connection IDs and their parsed
GET/HEAD request IDs, explicit admission rejections, and locally observed
shutdown/deadline/error reasons. It retains at most 10,000 accepted connections
and the first 32 rejection samples plus the full rejection count. No addresses,
URLs or headers are included. `handlerEnded` does not identify peer FIN/reset or
a URLSession retry. Connections without a parsed media request are retained.
The clock starts at listener construction, independently of the first-GET
profile origin. Do not subtract these timestamps from AVPlayer/Foundation times.
Parsed requests discarded by the existing 10,000-record limit have an explicit
`unrecordedRequests` count and are not classified as unparsed connections.
Missing request links, discarded requests, unfinished handlers or truncated rejection samples prevent
complete lifecycle evidence; none of this relaxes transaction completeness,
recovery budget, final high output or physical continuity gates.

Proxy boundary v4 separates `downstreamTerminal` (transport fields frozen) from
`taskComplete` and `taskOutcome` (0 success, 1 cancellation, 2 other error).
`terminal` is the final record seal after both sides have finished. DEBUG task
trace ownership survives playback cancellation until Foundation's metrics and
completion callbacks; playback cancellation itself does not wait. Late body/send
callbacks cannot change the frozen transport outcome. The capture still waits
for observer delivery, and missing completion cannot be treated as a complete
capture. v1–v3 retain their original interpretation. v4 success requires task
success and all transaction core intervals; cancellation metrics can still be
unavailable and are never fabricated. Missing server correlation still fails.

## Published-frame-triggered second fault

For owned physical production recovery diagnostics, `abr_accesslog.py
--triggered-fault-rate 0 --require-production-install` adds a single five-second
rate overlay. Use an initial-only static profile whose final step is at or before
15 seconds; combine with `--production-command pause-resume
--require-budget-exhaustion` to consume the first reservation without refund.
The production policy, attempt limit, and all existing acceptance readers are
unchanged. This is a separate triggered experiment, not the original fixed-time
profile run.

The test collector requests the fault only after an actual installation and at
least 48 published high frames spanning two seconds in one generation, with no
pause, pending seek, non-advancing position, or publication gap above 0.5 seconds.
The trigger position must be at most 70 seconds to leave observation time. A
separate owned control listener checks the per-run token and admits only one
bounded trigger. Requests have bounded body size and connection lifetime; failure
or a lost acknowledgement never retries the fault. The media listener keeps its
existing connection and shaping budgets.

`fault-trigger.json` retains device evidence and the server acknowledgement;
`fault-server.json` retains the server-side overlay interval and control outcomes.
`triggeredFaultObservation` binds both back to the unmodified frame and installation
records. Missing trigger, receipt mismatch, or absent second downshift remains a
failure. A bound trigger alone does not establish recovery, budget exhaustion,
continuity, or capability acceptance.

The static profile hash and `phaseBoundariesMs`/`phaseBytesWritten` still describe
the **base** timeline. During the separately recorded overlay interval, the overlay
rate replaces the base rate, including for in-flight bodies. Do not derive actual
rates from the base phase labels alone. Both the actual server overlay interval
and client observation interval are retained in their own monotonic clocks;
subtracting timestamps across those clocks is invalid.

`server-health.json` records up to 1,000 bounded service-loop samples with local
listener time, first-GET profile time, and accepted/active/rejected counts. It
helps distinguish an alive listener loop from a gap in parsed requests; it does
not prove that packets reached the host, diagnose the network path, or repair
missing historical logs. Frame publication remains a diagnostic, not calibrated
physical screen/audio continuity evidence.

### Offline retry attribution by proxy

`rendition_retry.py` reads explicit owned high-rendition asset paths (a JSON
array) and plain or gzip JSONL captures:

```sh
python3 -B tool/playback_network/rendition_retry.py \
  --boundaries capture/proxy-requests.jsonl.gz \
  --server-requests capture/requests.jsonl.gz \
  --high-assets high-assets.json --scoped
```

Without `--scoped`, the existing strict whole-capture correlation requirement
applies. Scoped output retains each unknown request and reports `highResets: null`
for unavailable scopes. An old proxy's uncorrelated cancellation does not prevent
observing another proxy's fully joined requests. Unmatched server media cannot be
assigned to a proxy, so it blocks all scoped retry observations. Ordering always
uses device uptime; replacement proxy traffic is never counted as the original
proxy retrying. The asset list must identify the actual owned rendition, including
its Period path, rather than unresolved MPD templates.

Exit zero means the diagnostic was produced, not that playback passed. Global
`fullyCorrelated` and every unknown request remain visible; `capabilityAccepted`
and `physicalOutputVerified` stay false. Zero Foundation byte counts do not prove
that a cancelled request was never sent. These observations do not replace or
rewrite the original receipt, explain AVPlayer's private penalty policy, or
change the recovery budget selected by the production implementation.

Production recovery captures now use `policySamplingVersion: 3`; legacy diagnostic
captures stay at v2. The independent v3 policy reader requires `budgetVersion: 2`,
`roundLimit`, `lastReservation`, `lastInstallation`, `highFrameCount`,
`highFrameSeconds` and `highFrameStart` on every decision. Times use capture
elapsed seconds. Attempts never decrease: the initial limit is two, and exactly
one new high-output publication window after a successful install can extend the
limit to four. The proof requires at least 48 actual publications over two seconds,
with advancing position, one generation and dimensions, and no gap above 0.5s.
The collector checks the proof against publication samples, allowing 50ms only at
sampled window boundaries; it does not treat geometry alone as publication proof.

Every reservation is at least 30 seconds after the preceding reservation.
Cooldown continues collecting the original consecutive eight-second bandwidth
windows (three requests, 955000bps, buffer five seconds and remaining twenty
seconds). Two qualified windows are retained while cooling; a bad window clears
them. Once cooldown ends, a fresh eligible sample may reserve from retained
windows with null `windowBitrate`/`windowRequests`. Cancellation and preparation
failure still spend their reservation. The original ticket backoff, preparation
deadline and authority/credential checks remain in force.

Use `--require-budget-renewal` with `--production-recovery`,
`--require-production-install` and `--production-command pause-resume` (or
`pause-prepared`) for the new repeated-downshift experiment. It requires attempt
two to install, actual high-frame renewal, a second published downshift on that
item, and a successful attempt-three installation followed by published high
frames, without a source or authority reset. The original EOF, final-high,
transaction and continuity readers still run. This flag is mutually exclusive
with `--require-budget-exhaustion`; that historical v2 requirement still demands
no third reservation and explicitly rejects v3 captures. Existing historical
receipts are unchanged. Neither path certifies physical screen/audio continuity.
# Transaction and server-receipt attribution

`request_attribution.py` reads proxy boundaries, server requests and the server
connection lifecycle together. All three inputs accept plain JSON/JSONL or gzip:

```sh
python3 tool/playback_network/request_attribution.py \
  --boundaries path/to/proxy-requests.jsonl.gz \
  --server-requests path/to/requests.jsonl.gz \
  --lifecycle path/to/connection-lifecycle.json
```

This is an offline diagnostic. Exit zero means the inputs produced a valid
diagnostic, not that playback passed. `strictProxyEvidencePassed` preserves the
existing proxy gate result; it is not whole-capture or release acceptance.
The tool separates final-transaction timing from all-transaction timing and
task-level parsed server receipts from individual transactions. Missing response
dates remain null; `before-recorded-request` means the request stage was not
recorded, not proof that no data was sent. Complete handler logs cover admitted
application connections, not the TCP backlog or packets. No resource, ordinal,
byte-count or cross-clock heuristic assigns an unknown transaction or request.

For new owned IPv4 captures, add `--transaction-connections` to
`abr_accesslog.py`. The native probe writes `transaction-connections.jsonl`,
and server lifecycle v2 records the same capture-scoped HMAC of each actual
client/server address and port tuple. Raw endpoints and the random key are not
exported. The launch manifest containing the key is temporary; the saved
`probe.xctestrun` omits it. This option requires a probe built with connection
capture support; missing sidecars remain unknown and fail the optional check.

`python3 tool/playback_network/transaction_connections.py CAPTURE_DIRECTORY`
recomputes the connection observation from saved raw files. Only a token unique
among accepted server connections establishes a connection binding; it does not
by itself prove HTTP parsing. Use the bound connection's lifecycle `requestIds`
and the request's correlation ID to establish parsing. Repeated tuples, proxy
connections, missing endpoints and absent callbacks remain unbound. Empty
transactions are explicit and never prove no packets. Strict transaction-time
and task-correlation failures are retained even when connection binding succeeds.
Historical captures without these fields cannot be retroactively bound.

Sidecar v2 also records `endpointFields`, a presence mask: local address=1,
local port=2, remote address=4, remote port=8. Zero means Foundation supplied none
of these fields; 15 means all four were supplied. With a null token, an incomplete
mask reports `endpoint-unavailable`, while 15 reports `unsupported-endpoint`
(outside the supported IPv4/nonzero-port encoding). Neither proves physical
non-delivery. Sidecar v1 is still readable with its original, less specific
unknown result; no mask is invented for earlier records.
