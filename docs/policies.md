# yl_player v0.2 policy semantics

Policies are requirements at an enforcement boundary. `assess` reports whether
a known route can enforce them, whether inspection is still needed, or why the
combination is incompatible. A compatible assessment does not prove the source
exists, its codecs initialize, or later media timing stays admissible.

## Networking and credentials

`YlNetworkPolicy.platformDefault()` delegates scheduling, connection, retry,
redirect, proxy, cookie, and transport behavior to the platform stack. It makes
no exact timing or retry promise. `YlNetworkPolicy.managed(...)` requests the
package-owned behavior described below. Android Media3 and Apple managed
fallback have separate implementations and supported routes; Apple container
rejections must not be applied to Android.

`YlHttpRequest.headers` contains ordinary metadata that may follow a
cross-origin resource. `credentials` contains Authorization, cookies, proxy
authorization, API keys, tokens, secrets, and every custom credential-bearing
value. Names are compared case-insensitively. Explicit credentials win a
spelling collision with ordinary headers.

Credentials are source-origin-only. Origin is normalized scheme, host, and
effective port. Same-origin descendants and redirects retain credentials. An
origin change strips every credential permanently for that request lineage,
including later redirects back, retries, HLS children, reconstruction, and
recovery. Ambient cookie/credential stores cannot bypass owned requests.
`platformDefault` credentials are supported only when the selected route proves
this same-origin behavior. A route whose redirects remain opaque must reject a
credential-bearing source rather than assume the platform protects it. Public
failures never contain a URI, header name/value pair, cookie, token, or native
stack.

### Managed request budgets

The connect timeout applies to each attempt or redirect hop through final
response headers, including DNS, connection, TLS, and server wait. The read
timeout measures body inactivity after headers and restarts on progress. Time
while package buffer backpressure intentionally suspends delivery is excluded.
These are per-attempt deadlines; there is no overall request or Load timeout
promise.

`maxRetries` excludes the initial attempt. Managed transport retries only
idempotent GET/HEAD requests after transient transport failures or HTTP 408,
429, 500, 502, 503, or 504. It does not retry validation, authentication,
certificate, cancellation, unsupported redirect, or other permanent failures.
Redirects use their own `maxRedirects` budget, which spans all attempts and
internal reopens for the original resource. Recovery cannot reset a terminal
request's budgets.

Retry `n`, starting at one, waits the smaller of `maxRetryDelay` and
`baseRetryDelay * 2^(n-1)`, saturating without jitter. A valid nonnegative
`Retry-After` delta or date takes precedence; a past date means zero delay. If
the requested delay exceeds `maxRetryDelay`, the request terminates instead of
retrying early. A malformed value falls back to exponential delay.

Apple managed HTTP is a bounded HTTP/1.1 reader over Network.framework and
system TLS. It supports fixed-length, chunked, and connection-close bodies,
limits aggregate headers/trailers to 64 KiB and each receive to 16 KiB, and
rejects invalid or ambiguous framing, upgrades, non-identity content encoding,
unsupported schemes, required proxy/PAC behavior, proxy authentication, custom
trust/pinning/CT requirements, and incompatible app transport restrictions. It
has no HTTP/2 or HTTP/3 fallback. HTTPS requires system certificate/hostname
verification, TLS 1.2 or newer, and ATS-compatible cipher suites.

## Buffer strategies

`automatic`, `lowLatency`, and `smoothPlayback` are tuning goals. Their actual
retention varies by route, media, and platform. `bounded` requests exact
package-owned minimum/maximum duration admission and a maximum assigned media
budget. A platform or route that cannot enforce all requested bounds rejects
with `policy.unsupported`; it does not silently downgrade.

Apple bounded fallback uses one Player-wide ledger shared by accepted playback,
candidates, and recovery. The budget covers retained ring/rewind bytes, packet
and conversion copies, submitted samples, queued and published frames,
scheduled PCM, and conservative receive/parser workspaces. Reported
`managedBufferedBytes` is the ledger's assigned reservations, including live
I/O workspace admission. It excludes metadata, empty ring spare capacity,
OS/TLS/decoder/GPU internals, and other process allocations. It is not a process
RSS measurement. Routes without that ledger leave managed buffer metrics null.

Minimum duration controls startup and rebuffering; EOF or actual producer
capacity may start nonempty playback below it. Maximum duration and bytes remain
enforced. Seek starts a new timing epoch without pretending old retained bytes
were released. Admission reserves room for observed packet and timestamp
advances. Unknown timing, arithmetic overflow, overlong packets, or an
unsatisfiable reorder window rejects with `policy.unsupported`. AAC-LC packet
duration is derived only from a complete matching AudioSpecificConfig; other
unknown durations are not guessed.

Package-controlled Apple HLS and bounded fallback cannot overlap while an
incompatible HLS owner, payload-send completion, bounded scope, or retained
payload remains alive. Cancellation alone does not prove release. Preparation
rejects with `policy.unsupported`, preserves accepted playback, and does not
retry or downgrade automatically.

## Decoder policy

`systemDefault` lets the selected engine choose. `hardwarePreferred` ranks or
requests hardware while allowing a truthful software or unknown result.
`hardwareRequired` must reject video unless the committed decoder has positive
hardware evidence.

Android classifies the initialized MediaCodec and filters software candidates
for `hardwareRequired`; `hardwarePreferred` retains fallback candidates.
Apple managed fallback reads the actual VideoToolbox
`UsingHardwareAcceleratedVideoDecoder` CFBoolean. Missing, numeric, or errored
properties are unknown. Its strict candidate retains the exact proven decoder
through commit and must prove hardware again after recreation. AVPlayer reports
unknown decoder mode and cannot satisfy `hardwareRequired` video. Audio-only
media has no video hardware requirement, although the current Apple managed
Matroska/FLV route itself requires a supported video stream.

The Apple hardware-evidence stage has a five-second monotonic deadline covering
queueing, decoder creation, and property acquisition. It is not an overall Load
or network timeout. Late native completion cannot commit. Each Player permits
one pending evidence probe, and macOS retains one fallback decoder permit, so a
strict replacement can reject while the prior decoder remains retained.

## Audio ownership

`YlAudioPolicy.appManaged` leaves audio focus/session/category decisions to the
application. Playback commands do not claim package ownership.

`pluginManagedMediaPlayback` asks the package to coordinate media playback. On
Apple platforms, process-wide leases serialize active plugin-managed playback;
the committed owner applies the media playback session/category on iOS, while
macOS retains its no-global-session behavior. Candidate preparation does not
steal ownership, and rollback restores the accepted owner. On Android, one
plugin-managed focus owner coordinates Media3 audio focus; replacement,
backgrounding, transient loss, stop, failure, and disposal transfer or release
that ownership without reviving stale playback intent. Multiple independent
application audio policies or non-media mixing requirements should use
`appManaged`.
