# iOS HTTP-FLV and Authenticated HLS Design

Date: 2026-09-03

## 1. Goal and support boundary

Extend `yl_player_ios` on iOS 15.0 and later with two production-facing network
paths without changing the public Dart API:

- HTTP/HTTPS FLV playback for live streams containing H.264/AVC or H.265/HEVC
  video and AAC or MP3 audio;
- HLS playback with caller-supplied HTTP headers applied consistently to
  playlists, media segments, initialization sections, and encryption keys.

Video decode remains hardware-only through VideoToolbox. FFmpeg remains a
minimized demux and packet-processing dependency with networking and video
software decoders disabled. HTTP-FLV is sequential and non-seekable. Legacy or
vendor FLV codecs such as Sorenson H.263, VP6, Nellymoser, Speex, AV1, and VP9
are outside this milestone.

The existing unheadered HLS AVPlayer path, progressive AVFoundation path, local
Matroska fallback, and HTTP/HTTPS Matroska VOD fallback must remain unchanged.

## 2. Considered approaches

### Selected: native dual path

HTTP-FLV reuses the owned fallback pipeline: URLSession byte input, minimized
FFmpeg demux, VideoToolbox video decode, native Apple audio conversion and
rendering, bounded queues, and Flutter Texture output.

Header-bearing HLS remains an AVPlayer source. An `AVAssetResourceLoader` maps
an internal URL scheme back to HTTP/HTTPS, loads and rewrites manifests, and
supplies AES key bytes. AVFoundation rejects TS/fMP4 HLS media delivered as
custom-scheme bytes (`CoreMediaErrorDomain -12881`), so media and initialization
resources are rewritten to a lifecycle-owned HTTP proxy bound to `127.0.0.1`.
That proxy forwards through URLSession with the same header-origin policy.

This approach retains AVPlayer's HLS adaptation and media behavior and keeps
FFmpeg networking and software video decode disabled. The loopback listener is
random-port, token-addressed, non-persistent, and cancelled with the asset.

### Required compatibility bridge: loopback HTTP media proxy

An initial resource-loader-only implementation passed manifests but failed when
AVFoundation consumed media from the custom scheme. Redirecting media to HTTP
restored playback but AVFoundation removed custom headers from the redirected
request. A loopback media proxy is therefore required for full-resource header
coverage. It never binds a public address or outlives its HLS asset, and it
streams without fully buffering or persisting media. Host applications must
permit local networking in ATS.

### Rejected: route both formats through FFmpeg

Routing authenticated HLS through FFmpeg would unify some input handling but
would require nested HLS resource networking inside the FFmpeg boundary and
would discard AVPlayer's mature adaptive streaming implementation. It also
conflicts with the package policy that URLSession owns iOS networking.

## 3. Public contract and routing

No Dart API or method-channel schema changes are required. Callers continue to
provide `YlMediaSource.network`, `formatHint`, `isLive`, and `headers`.

`YlIosSourceRoute` adds:

- `networkFlv` for an HTTP/HTTPS source with explicit `httpFlv` or `flv`, or an
  `automatic` source whose URL path ends in `.flv`;
- `headeredHls` for explicit `hls`, or an `automatic` `.m3u8` URL, when the
  source has one or more headers.

Routing remains deterministic before the current backend is quiesced. A
candidate source must finish format and decoder preflight before atomically
replacing the active backend. A failed FLV or HLS candidate must leave the
current source usable.

Header-bearing non-HLS AVPlayer sources remain rejected with
`container.headers_require_fallback`. Network Matroska live and all other
unsupported fallback combinations retain their existing errors.

Capability reports add `httpFlv` and `flv` to the iOS supported formats. HLS
remains reported as supported whether or not headers are present.

## 4. HTTP-FLV input and demux

The FFmpeg build enables the FLV demuxer plus the H.264, HEVC, AAC, and
`mpegaudio` packet parsers needed by the supported payloads while retaining all
current restrictions:

- FFmpeg HTTP/TLS and other networking remain disabled;
- FFmpeg video and audio decoders remain disabled;
- GPL and nonfree components remain disabled;
- URLSession remains the only network and TLS implementation.

`YlNetworkByteSource` gains an explicit sequential-live mode. A live source
starts at byte zero, does not issue Range requests, does not expose random
access, and does not interpret a normal stream with no declared content length
as completed until the URLSession task actually ends.

The FFmpeg bridge maps MP3 stream metadata alongside the existing H.264, HEVC,
and AAC mappings. Stream discovery accepts one supported video stream and zero
or one selected supported audio stream. Video configuration is converted into
a `CMVideoFormatDescription`; AAC and MP3 metadata is converted into the
appropriate AudioToolbox input format.

The existing fallback backend is generalized from Matroska-specific preparation
to a container-aware preparation result. Matroska keeps its current seek and
completion behavior. FLV sets `isLive=true`, `isSeekable=false`, omits duration,
and rejects `seekTo` without disturbing playback.

## 5. HTTP-FLV playback and reconnection

FLV demux runs on the existing serial demux queue and uses the existing bounded
packet, decoded-frame, and PCM queues. Low-latency mode is the default behavior
for live FLV unless the caller explicitly selects another buffer mode. Existing
byte ceilings remain hard limits; no unbounded queue or persistent cache is
introduced.

At initial startup and after every reconnect, video packets are discarded until
the first usable keyframe. The media clock is anchored from the first accepted
audio/video timestamp. Timestamp discontinuities reset the scheduling anchor
instead of allowing an ever-growing live backlog.

A transport interruption cannot append a new FLV file header to an existing
demux context. Instead, the backend performs a live-source reconstruction:

1. enter buffering and invalidate the old source generation;
2. cancel input and join the old demux worker;
3. clear encoded packets, decoded frames, scheduled PCM, and clocks;
4. reconnect from byte zero after the configured retry delay;
5. create a new demux context and rebuild audio/video decoders if stream
   configuration changed;
6. resume at the first usable keyframe.

Reconnect attempts use `YlNetworkPolicy.maxRetries`,
`YlNetworkPolicy.baseRetryDelay`, and `YlNetworkPolicy.maxRetryDelay`. Each
attempt emits the existing retry event. Exhaustion emits
`network.retry_exhausted`; retries are never infinite. Lifecycle reconstruction
uses the same process and does not claim to resume a historical live position.

## 6. AAC and MP3 audio

AAC continues through the current Apple AAC converter. The audio conversion
boundary is generalized so MP3 packets can be configured with
`kAudioFormatMPEGLayer3` and converted to the existing Float32 PCM output.
AudioToolbox, not FFmpeg, decodes both formats.

The renderer preserves volume, speed, interruption handling, and audio clock
semantics. Audio-only FLV is outside this milestone because the public player is
video-oriented; a stream without supported video returns a video decoder error.
A supported video stream without audio remains valid.

## 7. HLS resource loader

Header-bearing HLS uses a new loader owned for the complete lifetime of its
`AVURLAsset`. The top-level HTTP/HTTPS URL is encoded into an internal scheme.
Every URL requested through that scheme is decoded, validated as HTTP/HTTPS,
and loaded by a package-owned ephemeral URLSession.

For HLS manifests, the loader resolves and rewrites:

- non-comment URI lines for variants, renditions, segments, and low-latency
  parts;
- quoted `URI` attributes, including `EXT-X-KEY`, `EXT-X-MAP`,
  `EXT-X-MEDIA`, `EXT-X-I-FRAME-STREAM-INF`, `EXT-X-SESSION-KEY`, and
  preload/rendition reports;
- relative, absolute, query-only, and parent-relative URLs.

AES key resources are streamed without content transformation through the
resource loader. Media and initialization resources are fetched by the loopback
proxy, which forwards status, MIME type, content length, and byte-range metadata.
Cancellation tears down resource-loader tasks, proxy tasks/connections, and the
listener.

The caller's non-sensitive headers are applied to the top-level manifest and
all rewritten child resources. `Authorization`, `Cookie`, and
`Proxy-Authorization` are applied only when the requested resource has the same
scheme, normalized host, and effective port as the original top-level HLS URL.
They are stripped from cross-origin children and cross-origin redirects.
Same-origin redirects retain all headers. URLSession's automatic cookie store is
disabled so response cookies cannot bypass exact-origin filtering.
Package-managed Range headers may override a caller-supplied Range header for an
AVFoundation byte-range request.

Unheadered HLS continues to construct a normal `AVURLAsset` and never creates a
resource loader.

## 8. State, errors, and lifecycle

HTTP-FLV publishes `engine: nativeFallback`; header-bearing HLS publishes
`engine: avPlayer`. Existing state, track, first-frame, retry, metrics, and
texture events remain wire-compatible.

Stable new container errors are:

- `container.flv_open_failed` when FLV input cannot be opened;
- `container.flv_malformed` when packet or stream metadata is invalid;
- `container.hls_manifest_invalid` when a manifest cannot be decoded or safely
  rewritten.

Existing network error families cover HTTP status, redirects, connection
timeout, read timeout, cancellation, and retry exhaustion. Existing
`decoder.video_hardware_unavailable` applies when H.264 or HEVC cannot obtain a
required hardware decoder. Audio configuration and conversion failures use
codec-specific diagnostics under the existing decoder-unsupported category.

Every resource-loader callback and FLV demux/decode callback carries a source
generation. Stale callbacks after open, replacement, background release, or
dispose are ignored. Dispose is idempotent and cancels URLSession tasks, resource
loading requests, retry timers, demux workers, decode sessions, and audio work.

## 9. Verification strategy

### Unit and contract tests

- Router tests cover explicit and automatic FLV, header-bearing HLS, malformed
  URLs, unsupported headers on non-HLS sources, and failed-candidate rollback.
- FFmpeg build-contract tests require the FLV demuxer and needed parsers while
  continuing to reject FFmpeg networking, GPL/nonfree options, and software
  video decoders.
- Manifest tests cover master/media playlists, relative and absolute lines,
  every supported `URI` attribute, query-only references, CRLF preservation,
  malformed UTF-8, and non-HTTP targets.
- Header-policy tests cover default ports, host normalization, same-origin
  propagation, cross-origin non-sensitive propagation, sensitive-header
  stripping, redirects, and caller/package Range precedence.
- FLV tests cover H.264/AAC, H.264/MP3, H.265/AAC, video-only input, unsupported
  codecs, missing configuration, first-keyframe gating, timestamp reset,
  non-seekability, retries, exhaustion, cancellation, and bounded memory.

### Integration tests

A loopback test server provides deterministic fixtures and records requests.
The HLS suite proves that custom headers reach the main playlist, child
playlist, segments, initialization section, and AES key while sensitive headers
are absent from cross-origin resources. It opens through AVPlayer and requires a
native texture first frame.

The HTTP-FLV suite serves chunked live fixtures, delays reads, disconnects at
controlled offsets, and changes stream configuration after reconnect. It
requires a first frame, AAC and MP3 audio setup, H.264 and H.265 hardware-decoder
outcomes, bounded buffers, a non-seekable state, retry events, and terminal
exhaustion after the configured limit.

Simulator runs may accept the exact hardware-unavailable result for a codec the
runtime cannot decode. Physical iPhone/iPad acceptance must verify H.264 and
H.265 first frame, audio for AAC and MP3, reconnect behavior, memory pressure,
and at least a 30-minute live run before the feature is described as stable.

The final automated gate runs the FFmpeg contract, complete XCTest suite,
complete Dart tests, Flutter analyzer, existing HLS/MKV integrations, new
authenticated-HLS integration, and new HTTP-FLV integration.

## 10. Documentation and compatibility

Package README and changelog entries describe the exact codec, header-origin,
seek, retry, and hardware requirements. The FFmpeg third-party notices and
rebuild contract remain valid because the added demux/parser components are
LGPL-compatible and the exact configure allowlist is recorded.

This work must not change Android behavior or the stable Dart model. Existing
applications that do not use HTTP-FLV or HLS headers must observe no behavioral
change.
