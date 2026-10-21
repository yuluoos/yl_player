# Diagnostics and safe failure handling

Asynchronous API failures use `YlPlayerException`, whose `failure` is an
immutable `YlFailure`. Failed authoritative playback also appears as
`state.failure` and a correlated `YlPlaybackFailedEvent`.

## Stable fields

`category` is a broad handling class: `cancelled`, `unsupported`, `source`,
`network`, `container`, `decoder`, `render`, `resource`, `protocol`, `platform`,
or `internal`.

`code` is the stable programmatic identity. Core codes are:

| Code | Meaning |
|---|---|
| `player.disposed` | The Player is terminal |
| `platform.unavailable` | No endorsed implementation is available |
| `platform.incompatible` | The implementation does not implement SPI major 2 |
| `load.cancelled` | A newer operation cancelled the pending Load |
| `session.stale` | A replaced/stopped Session handle was used |
| `policy.unsupported` | The selected route cannot enforce a requested policy |
| `source.invalid` / `source.missing` | Invalid source metadata or unavailable local source |
| `network.failed` | Managed or platform network operation failed without a more specific structured classification |
| `network.dns_failed` | A platform DNS error proved that the source host could not be resolved |
| `network.http_forbidden` | The media server returned HTTP 403; the message includes HTTP 403 and access guidance |
| `network.http_status.<status>` | Apple/Android upstream HTTP rejection, with the exact three-digit status (for example `network.http_status.404`) |
| `network.read_timeout` / `network.connect_timeout` | Reading or connecting exceeded its deadline |
| `network.tls_failed` | Structured TLS negotiation or certificate validation failure |
| `network.connection_failed` / `network.connection_lost` / `network.offline` | Structured connection refusal, connection interruption, or unavailable network |
| `container.unsupported` | No supported container route |
| `decoder.unsupported` / `decoder.unavailable` | Unsupported media or unavailable required decoder |
| `render.audio_engine_failed` | Apple native audio output could not start or became invalid; check the output device and reload the media |
| `resource.exhausted` | A bounded native resource could not be acquired |
| `protocol.mismatch` | Native/Dart state or transport violated the SPI contract |
| `platform.failure` / `internal.failure` | Safe fallback identities for platform/internal faults |

Platforms may add validated extension codes. Treat unknown codes within a known
category conservatively.

`scope` says what authority failed: `command` leaves broader state unchanged,
`session` terminates or rejects one session, and `player` makes the Player
unusable. `retryable` is a property of that failure, not permission to bypass
the configured retry budget or repeat a non-idempotent application action.
`network.dns_failed` may be retryable, but remains subject to the existing
managed retry budget and cancellation/session fences. `network.http_forbidden`
is not retryable. These codes refine failures that previously appeared as
`network.failed` (Android DNS) or `network.http_status` (Apple HTTP 403).

DNS classification requires a bounded native cause chain containing
`UnknownHostException` on Android or an `NSURLErrorDomain` DNS/host lookup code
on Apple. HTTP 403 classification requires the structured response status.
Messages and diagnostic strings are never parsed to infer a cause. Apple and
Android HTTP responses use `network.http_status.<status>`;
403 retains `network.http_forbidden`. Public boundaries accept only canonical
status values from 100 through 599 and regenerate fixed messages. Response
bodies, server reason phrases and arbitrary native prose remain private.
Transport failures without an HTTP response use a structured transport code,
or `network.request` (Apple) / `network.failed` (Android) when the transport cause is unknown.

The Apple HLS/DASH loader and media proxy log upstream failures with
`httpStatus`, `code`, a safe reason and a request-log `diagnosticId` (separate
from the final playback failure ID). `httpStatus=none` means
no HTTP response was received. Proxy-generated 502 is not reported as an
upstream HTTP status. The loader keeps at most 16 unresolved resource failures
for its playback item. A successful request for the same resource clears the
old failure, and cancellation clears the item history and rejects late callbacks.
An AVPlayer network/source failure uses this evidence; explicit decoder and
container failures retain their own diagnosis. HTTP error response bodies still
complete normally through the proxy. Retry budgets are unchanged; public
retryability follows the classified failure code. Managed retry exhaustion
retains its existing code, with the attempted HTTP
status recorded in the native attempt log.

Android managed and default HTTP requests log failed attempts with the same
safe `httpStatus`, `code`, `reason` and `diagnosticId` fields. Retry responses
record the actual upstream status after restoring any internal transport
sentinel. Body-read failures also record the response status when available.
Attempt IDs are separate from the final command/session failure ID.
Media3 errors keep their cause through decoder readiness and session publication;
FFmpeg byte sources retain read/seek failures across JNI exception clearing.
Successful byte reads clear retained evidence. HTTP 401/404/429/5xx, DNS,
connection/header deadline, read timeout, TLS, connection refusal/interruption,
and redirect-limit failures receive specific safe diagnoses when supported by
structured evidence. Retry and redirect budgets remain unchanged.

`message` is safe user-facing text supplied at the public boundary. Native
adapters replace untrusted native text with package-owned fixed wording. Known
Apple codes describe the failed stage, known cause, and a safe next action;
unknown errors explicitly say that the reason is unknown. Applications may
display it, but should branch on category/code rather than wording.

`diagnosticId` is an opaque correlation token. Include it with code, category,
scope, app build, package version, platform/OS version, and a local timestamp in
support logs. The ID is useful only when matched to protected implementation
logs from the same run; it is not a source locator or globally unique incident
number.

```dart
try {
  await session.play();
} on YlPlayerException catch (error) {
  final failure = error.failure;
  logger.warning(
    'playback code=${failure.code} category=${failure.category.name} '
    'scope=${failure.scope.name} diagnostic=${failure.diagnosticId} '
    'reason=${failure.message}',
  );
}
```

Never log or attach source URIs/paths, query strings, ordinary request headers,
credentials, cookies, tokens, decoder identities, native error strings, native
stacks, proxy configuration, or media payload bytes. Do not stringify arbitrary
caught objects: use the `YlFailure` fields or a static fallback message.

There is no public method that exposes raw native diagnostics. Do not document
or depend on implementation methods, Pigeon messages, platform channels, or
private native logs as an application API. `toString()` redacts sensitive model
fields and unsafe metadata, but explicit safe-field logging remains preferred.

## Apple audio output failure and reload

`render.audio_engine_failed` has category `render` and is not automatically
retryable. Its fixed public message is: “Audio output is unavailable. Check the
selected audio device and reload the media to rebuild playback.” This code
covers both engine startup failure and output configuration invalidation; it
does not by itself prove that the user changed devices.

For a session failure, show a **Reload media** action after the user checks the
selected system audio output. On explicit activation, call
`player.load(source, options: options)` with the application's retained source
and intended load options, then use the returned session handle and observe its
`ready`/play Futures. A successful replacement invalidates the old handle. Do
not loop on the failed session's `play()` or automatically retry a failed Load:
the invalidated native output graph has been stopped and cannot resume.

If resuming a seekable VOD, retain the last known position and request it via
Load's start-position option; do not assume that reloading restores position,
track choices, or playback intent automatically. Observe any new load/play
failure and display its safe message. An application may localize the message
by stable code (for example: “音频输出不可用，请检查所选音频设备并重新加载媒体。”).
Actual device-change recovery and long-duration playback remain separate
acceptance items; this guidance does not establish that they passed.

## Optional script resolver errors

The independent `yl_player_source_resolver` reports `YlScriptException` before a
media source is handed to the player. Its stable `script.*` code, fixed
phase/scope, per-resolution `diagnosticId`, safe Chinese `message` and
`retryable` flag identify the failed attempt without retaining script text,
URL, parameters, headers or arbitrary exception text. The player transport
schema and `YlFailure` contract are unchanged.

Known HTTP 403 is `script.http_forbidden` and is not retryable. Timeout,
cancellation, resource limits, unsupported host APIs, invalid results and
explicit expiry are separate classifications. A script's own nonempty `error`
field takes precedence over a returned URL and produces a fixed safe error;
its original text is never shown. Unknown expiry is not inferred from a token.

Cancellation completes after transport/native cleanup; a business interface
should suppress cancellation feedback when switching channels. Applications
may resolve again explicitly, but the module does not automatically retry
requests, replace media, or switch to another source. See the
[resolver report](superpowers/reports/2026-09-22-script-resolver.md) for verified
behavior and boundaries.
