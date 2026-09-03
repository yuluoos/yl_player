# iOS Network MKV VOD Design

## 1. Goal and status boundary

Extend the existing iOS native fallback so an HTTP or HTTPS Matroska VOD source
can be demuxed by the minimized FFmpeg bridge and rendered by the existing
VideoToolbox/AAC pipeline without changing the public Dart playback API.

This milestone is complete when its automated Simulator gates pass. Physical
device playback, 30-minute endurance, and Instruments/memgraph measurements
remain explicitly deferred release gates. Documentation may describe the
feature as experimental after automated acceptance, but must not claim verified
device smoothness or stable support.

## 2. Scope

### Included

- iOS 15.0 and later.
- `YlMediaSourceKind.network` sources using HTTP or HTTPS.
- Explicit `YlFormatHint.matroska`, or `automatic` with a `.mkv` URL path.
- VOD only: `isLive` must be false.
- H.264 or H.265 video through required-hardware VideoToolbox.
- Zero or more AAC-LC audio tracks through the existing native audio renderer.
- Arbitrary application request headers, subject to redirect credential rules.
- HTTP redirects, byte-range discovery, bounded read-ahead, cancellation,
  timeout, retry, reconnect, seek, background release, and foreground rebuild.
- Servers without Range support may play sequentially from byte zero.

### Excluded

- Network Matroska with `isLive=true`.
- HTTP-FLV, MPEG-TS fallback, WebM fallback, and remote AVI/MPEG-PS.
- FTP, WebSocket, RTSP, SMB, and non-HTTP transports.
- Subtitles, DRM, downloads, persistent/offline cache, and source-site parsing.
- FFmpeg network, TLS, software video decode, or audio decode libraries.
- Authentication refresh callbacks or cookie persistence owned by the package.

## 3. Chosen architecture

Use `URLSession` for all network and TLS behavior and expose a synchronous,
bounded byte-source interface to FFmpeg through custom AVIO callbacks. Keep the
FFmpeg build configured with `--disable-network`.

This separates responsibilities:

- `YlNetworkByteSource` owns URL validation, headers, redirects, range requests,
  timeout, retry, validators, cancellation, and the bounded byte cache.
- `YlByteRingBuffer` owns byte offsets, capacity, blocking reads, eviction,
  cancellation wakeups, and memory-pressure shrinking.
- `YlFFmpegBridge` adapts byte-source callbacks to `AVIOContext` and keeps all
  Matroska parsing and packet ownership in the existing C boundary.
- `YlPreparedFallback` validates either a local or network input, copies the
  source recipe needed for rebuild, and performs the existing media/decoder
  preflight.
- `YlFallbackBackend` remains the only fallback playback engine. It continues
  to own packet scheduling, VideoToolbox, AAC output, clocking, Flutter Texture,
  lifecycle, and generation isolation.
- `YlIosPlayer` prepares a network candidate off the main thread and atomically
  replaces the active backend only after the entire candidate is ready.

The alternative of enabling FFmpeg HTTP/TLS is rejected because it enlarges the
binary and dependency surface and fragments networking policy from iOS. Full
pre-download is rejected because it delays startup, uses persistent storage, and
does not provide streaming VOD behavior.

## 4. Source routing

`YlIosSourceRoute` gains `networkMatroska`. Routing follows this order:

1. Reject malformed URIs and non-HTTP(S) network schemes.
2. Route local Matroska exactly as before.
3. For network sources, route explicit `matroska` or automatic `.mkv` to
   `networkMatroska` only when `isLive == false`.
4. Reject network Matroska marked live with
   `container.network_mkv_live_unsupported`.
5. Custom headers no longer cause rejection for local or network Matroska;
   AVPlayer sources with custom headers remain rejected.
6. HTTP-FLV and every other unimplemented fallback combination remain
   `container.native_fallback_required`.

Routing is deterministic and does not optimistically open with AVPlayer first.

## 5. Network byte-source contract

The Swift-facing contract is synchronous because FFmpeg AVIO callbacks are
synchronous:

```swift
protocol YlByteSource: AnyObject {
  var length: Int64? { get }
  var supportsRandomAccess: Bool { get }
  var currentOffset: Int64 { get }
  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
  func seek(to offset: Int64) throws -> Int64
  func cancel()
  func handleMemoryWarning()
}
```

`read` returns a positive byte count, returns zero only at confirmed EOF, and
throws for cancellation or terminal transport failures. `seek` returns the new
absolute byte offset. The source must never invoke URLSession completion work on
the FFmpeg worker that is blocked in `read`.

The C bridge receives an opaque source pointer and C callbacks rather than a URL:

```c
typedef int32_t (*YLFReadCallback)(void *opaque, uint8_t *buffer,
                                   int32_t capacity);
typedef int64_t (*YLFSeekCallback)(void *opaque, int64_t offset,
                                   int32_t whence);
typedef void (*YLFCancelCallback)(void *opaque);

YLF_EXPORT int32_t ylf_open_callbacks(
    void *opaque,
    YLFReadCallback read_callback,
    YLFSeekCallback seek_callback,
    YLFCancelCallback cancel_callback,
    YLFMediaContextRef *out_context,
    YLFMediaInfo *out_info);
```

`ylf_open_callbacks` allocates an `AVIOContext`, sets `AVFMT_FLAG_CUSTOM_IO`,
opens Matroska without a network URL, and reuses the existing stream discovery.
The bridge maps callback EOF, cancellation, and I/O failures to distinct result
codes. Closing a media context invokes cancellation before freeing AVIO memory,
wakes any blocked reader, and preserves the existing zero-outstanding-packet
guarantee.

## 6. HTTP behavior

### Initial request and capability discovery

The initial GET requests `Range: bytes=0-` unless the caller supplied a Range
header. Package-generated Range always wins because arbitrary caller ranges
would invalidate FFmpeg absolute offsets.

- A valid `206` response must include a `Content-Range` beginning at the
  requested offset. It establishes random access and, when present, total size.
- A `200` response at offset zero establishes sequential-only playback.
- A `200` response to a nonzero range request is a terminal
  `network.range_not_supported` error; its bytes are not appended.
- `416` maps to EOF only when the requested offset equals a known resource
  length. Otherwise it is a terminal range error.
- Other non-2xx statuses are terminal HTTP errors except those explicitly
  eligible for retry.

`Content-Length` and total `Content-Range` are validated against signed 64-bit
limits. Responses that would overflow offsets are rejected.

### Redirects and credentials

Only HTTP and HTTPS redirect destinations are accepted. Redirect count is
bounded by `YlNetworkPolicy.maxRedirects`.

- Same-origin redirects retain caller headers.
- Cross-origin redirects remove `Authorization`, `Cookie`, and
  `Proxy-Authorization` case-insensitively.
- Package-owned Range and conditional headers are rebuilt for the destination.
- Diagnostics redact sensitive header values and omit URL query and fragment.

### Validators and changed content

The byte source records a strong ETag when available; otherwise it records
`Last-Modified` plus known resource length. Reconnect and seek requests use
`If-Range`. If a response proves that the resource changed, cached bytes are
discarded and playback fails with `network.content_changed`; bytes from two
representations are never concatenated.

### Retry

Connect and read timeouts come from `YlNetworkPolicy`. Retry delay is exponential
from `baseRetryDelay` and capped at `maxRetryDelay`; `maxRetries` counts retries
after the initial attempt. Each retry emits the existing `YlRetryEvent` without
including credentials or a full query string.

Retry is allowed for transient URL errors, HTTP 408, 429, and 5xx. A connection
that fails after delivering bytes resumes only when random access was confirmed.
A sequential-only response that fails after byte delivery terminates rather
than silently concatenating a new response.

## 7. Buffering and memory

`YlByteRingBuffer` stores contiguous bytes with absolute start/end offsets. It
uses a condition variable so producers wait when full and FFmpeg waits when no
data is currently available. Cancellation and terminal errors wake both sides.

Default network byte-cache ceilings are:

| Buffer mode | Network byte cache |
| --- | ---: |
| `lowLatency` | 4 MiB |
| `automatic` / `balanced` | 8 MiB |
| `stable` | 16 MiB |

The package-owned managed-media ceilings are:

| Buffer mode | Network bytes | Scheduled PCM | In-flight encoded packet |
| --- | ---: | ---: | ---: |
| `lowLatency` | 4 MiB | 1 MiB | 2 MiB |
| `automatic` / `balanced` | 8 MiB | 2 MiB | 4 MiB |
| `stable` | 16 MiB | 4 MiB | 8 MiB |

For `custom`, `maxBufferBytes` is the total package-owned managed-media budget
shared by those three children. Values below 3 MiB are rejected when a network
fallback source is prepared, without affecting AVPlayer use by the same
controller. From the bytes above the three 1 MiB floors, 70% goes to the network
cache, 20% to scheduled PCM, and the remainder to the in-flight packet. The
three integer ceilings must sum to exactly `maxBufferBytes`. A single packet or
PCM buffer larger than its child ceiling fails with a structured resource error
rather than temporarily exceeding the limit.

The budget covers memory directly retained by these package components. FFmpeg
container/index metadata, URLSession/TLS implementation buffers, and
VideoToolbox allocations are not falsely reported as hard-bounded by this API.
VideoToolbox output remains limited to three decoded frames. No encoded bytes or
decoded frames cross the Dart boundary.

On memory warning, the network cache ceiling becomes 2 MiB, consumed bytes are
evicted immediately, read-ahead pauses until under the new ceiling, and existing
fallback frame/PCM release behavior remains in force. The normal ceiling is
restored only after a later foreground rebuild.

## 8. Open, command, and lifecycle behavior

Network probing can block on I/O and therefore never runs on Flutter's main
thread. `YlPlayerIosPlugin` keeps Flutter method results pending while
`YlIosPlayer` prepares a candidate on a dedicated serial queue. Completion is
delivered exactly once on the main thread.

Every preparation has a source generation:

- A newer `open` cancels the older preparation.
- `dispose` cancels preparation, active network reads, retry timers, and AVIO
  waits before unregistering the texture.
- Late URLSession callbacks, retries, decoded frames, and method completions
  whose generation is stale are ignored after releasing their resources.
- The current backend remains active until the candidate passes container,
  stream, AAC configuration, and hardware-decoder preflight.
- Candidate failure leaves the current backend intact.

Range-capable seek reuses the existing ordered fallback transaction: pause,
advance generation, stop demux, clear bounded queues, make a byte-range seek,
flush FFmpeg, reset audio, recreate VideoToolbox, install independent post-seek
PTS gates, and restart demux.

Sequential-only sources publish `isSeekable=false`. A `seekTo` command returns
`network.range_not_supported` without disposing the backend or changing the
current playback position.

Backgrounding releases URLSession tasks, the AVIO context, packet queues,
VideoToolbox, audio, frames, and display link while retaining the URL, sanitized
header recipe, validators, selected track, playback intent, and media time. On
foreground activation, a range-capable source rebuilds at the saved media time.
A sequential-only source rebuilds from byte zero in paused state.

## 9. Errors

Stable errors added by this milestone include:

| Category | Code | Meaning |
| --- | --- | --- |
| `container` | `container.network_mkv_live_unsupported` | Network MKV was marked live. |
| `network` | `network.http_status` | Terminal HTTP response; sanitized status is diagnostic data. |
| `network` | `network.redirect_limit` | Redirect limit exceeded. |
| `network` | `network.invalid_redirect` | Redirect scheme or destination is invalid. |
| `network` | `network.connect_timeout` | Connection deadline expired. |
| `network` | `network.read_timeout` | No bytes arrived before the read deadline. |
| `network` | `network.range_invalid` | Content-Range does not match the requested offset. |
| `network` | `network.range_not_supported` | Random access was requested from a sequential source. |
| `network` | `network.content_changed` | Validator or length changed during reconnect/seek. |
| `network` | `network.retry_exhausted` | Transient transport retries were exhausted. |
| `cancelled` | `network.cancelled` | An open/read was superseded or disposed. |
| `resource` | `resource.network_buffer_limit` | One required object exceeds its hard encoded budget. |

Cancellation caused by replacement or disposal is used to complete the affected
command but is not emitted as a persistent player error. Existing decoder and
container errors remain unchanged.

## 10. Testing and acceptance

### C bridge tests

- Open the generated H.264/AAC MKV through callback-backed in-memory bytes.
- Read metadata and packets, perform absolute seek, and reach EOF.
- Cancel a callback blocked in read and prove it wakes.
- Close with retained packets and verify
  `ylf_debug_outstanding_packet_count() == 0`.
- Reject callback failures and non-Matroska input with stable bridge results.

### Swift network tests

Use an injected `URLSession` backed by `URLProtocol` fixtures to verify:

- Valid 206 parsing, a sequential 200 response, invalid Content-Range, and 416.
- Seek creates the correct Range request.
- Same-origin header retention and cross-origin credential stripping.
- Redirect limits and non-HTTP redirect rejection.
- Connect/read timeout mapping.
- Transient retry schedule and retry exhaustion.
- Exact-offset reconnect after partial delivery.
- ETag/Last-Modified content-change rejection.
- Ring-buffer hard ceilings, producer/consumer blocking, EOF, cancellation,
  and memory-warning shrink.
- Concurrent open replacement and dispose produce exactly one completion and no
  stale backend replacement.

### Flutter integration

The example integration test starts a loopback HTTP server that serves the
generated fixtures with deterministic Range behavior. It verifies:

- Network H.264/AAC MKV reaches the native fallback and first-frame path, or
  returns the exact hardware-unavailable error on Simulator.
- A Range-capable source seeks and reports the requested media position.
- Both AAC tracks are exposed and selectable.
- A sequential source reports `isSeekable=false` and survives a rejected seek.
- A failed network-MKV candidate does not tear down current HLS playback.

### Complete automated gate

Run full XCTest, existing HLS/local-MKV/network-MKV integration, all Dart tests
and analysis, Android debug build, iOS Simulator debug build, FFmpeg build
contract, formatting, `git diff --check`, and four zero-warning pub dry runs.

## 11. Publication and compatibility

The public Dart API and federated package layout remain unchanged. The shipped
FFmpeg artifact still contains no network/TLS implementation, so the existing
LGPL notices and reproducible build contract remain valid. New Objective-C and
Swift source files must be included by both CocoaPods and Swift Package Manager,
and test media/server helpers remain excluded from published package archives.

After automated acceptance, README and changelog text may say “experimental
iOS HTTP/HTTPS MKV VOD.” They must also state the codec limits, required hardware
decode, bounded memory, sequential-server seek limitation, deferred physical
device validation, and unsupported live/HTTP-FLV boundary.
