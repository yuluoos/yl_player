# Custom live AirPlay

The user explicitly requests continuing the implemented AirPlay feature with
RTMP and HTTP-FLV live support. This authorizes implementation of the previously
explained continuous segmentation/sliding-playlist path. Existing VOD behavior
and ordinary managed playback remain intact.

## Scope and decisions

- Apple iOS 15/macOS 12, same `YlLoadOptions(airPlay: true)`, picker and state.
- RTMP (existing non-TLS RTMP transport) and HTTP(S)-FLV live, H.264 and optional
  mono/stereo AAC-LC, compressed passthrough. RTMPS and other codecs retain
  explicit rejection; no transcoder, binary rebuild or private AirPlay API.
- Use production YlOpenedMedia with RTMP recipe or sequential HTTP input. Reuse
  source validation, header/credential boundaries and cancellation.
- A worker continuously writes fMP4 HLS. Load commits when a standards-valid
  initial live playlist is available, without waiting for input EOF. No seek or
  complete-file timestamp scan. Preserve valid FLV DTS/PTS (including B frames).
- Sliding media sequence and period-specific init maps; no VOD/ENDLIST tag while
  running. Atomic playlist publication, published-resource allowlist, constant
  target duration, and receiver-safe expired-segment retention. Bound bytes,
  segment count, individual packets and keyframe spans. Bounds and startup
  latency are implementation choices to document, not user-selected numbers.
- Reconnect transient disconnection at most three times with 0.5/1/2 second
  backoff. Restart demux/writer, wait for a keyframe, publish discontinuity and
  new init map. Cancel promptly; unsupported codecs/configuration/timelines are
  terminal, not infinite retries. Terminal failure reaches the active session.
- Load cancellation, stop, disposal and successful replacement stop the worker,
  cancel network reads, close HTTP connections and retire files without racing
  in-flight readers. Failed replacement preserves the accepted live producer.
- Background behavior inherits the AirPlay route and audio gates. Producer
  ownership must survive suspension needed for subsequent restoration without
  reconnecting or reopening the temporary HLS URL as a custom input.
- Standard HLS and finite custom VOD preserve their existing routes/limits.
- Physical AirPlay and CarPlay remain separate unverified device acceptance.

## Implementation boundaries

1. Live store: immutable init/media files, atomic dynamic index, time/count/byte
   retention, safe opening under lock. Extend current HTTP server using a resource
   resolver; preserve VOD constructor and range/security tests.
2. Live remux owner: background input/mux/recovery, startup readiness, period
   lifetime, retained cancellation and terminal error subscription. Uses store.
3. Routing/lifetime: admit RTMP/HTTP-FLV live, preserve RTMP validation, pass
   retained owner through YlAirPlayPreparedMedia, fence terminal callbacks by
   current backend generation. Existing Dart API unchanged.
4. Tests: rolling playlist and retention, real live FLV chunks and RTMP test
   server, AVPlayer readiness while producer remains connected, recovery,
   cancellation, bounded resources and VOD regression. Build both Apple targets.
