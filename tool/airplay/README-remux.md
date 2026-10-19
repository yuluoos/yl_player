# AirPlay compressed remux tests

Run on macOS with Xcode command-line tools and a running Wi-Fi/Ethernet IPv4 interface:

```sh
tool/airplay/run_remux_tests.sh
```

The test requires permission to bind a temporary LAN HTTP listener. A sandbox that denies `bind` returns `airplay.lan_unavailable` with an EPERM diagnostic. It does not contact an AirPlay receiver.

The standalone harness substitutes app configuration and network-input boundaries. It uses the shipped FFmpeg framework for real local demux, production remux/server code, AVFoundation's compressed HLS writer, AVPlayer video output, and AVAssetReader AAC-to-PCM decoding. Fixtures are existing repository assets; no FFmpeg executable is required.

Checks cover H.264/AAC MKV, FLV, MP4, a longer multi-segment MKV, generated playlist and segment retrieval, byte ranges, HEAD, method/path/capability rejection, AVPlayer readiness and decoded frames, finite duration, preserved AAC with successful PCM decode, seeking, listener shutdown on release, unsupported HEVC/MP3 and live inputs, pre-cancellation and in-flight cancellation, sparse oversized-input rejection, and FFmpeg packet ownership. The MP3 rejection fixture emits an expected demux codec-parameter warning.

`YlAirPlayRemux.prepare(source:configuration:token:)` returns `YlAirPlayPreparedMedia`; retain it while consuming `url`. Releasing it closes all HTTP connections and removes its private temporary directory.

The mechanism is complete-VOD preparation, not real-time transcoding. A bounded timestamp scan followed by seek-to-zero and compressed remux preserves presentation timestamps and builds a monotonic decode clock for B-frames, including Matroska sources with missing or unreliable DTS. Only the first H.264 video and optional first mono/stereo AAC-LC audio track are exported. Live, DRM, playlists, other codecs, ADTS AAC, invalid timelines, and non-seekable HTTP inputs are rejected.

Limits: 120 seconds of preparation, six hours of source duration, 500,000 video samples, 512 MiB input packets/local-file size, 512 MiB output files, 8 MiB per packet, and 32 MiB per video keyframe interval. The HTTP origin binds one active physical LAN IPv4 interface, uses a fresh random capability path and explicit immutable filename allowlist, accepts GET/HEAD with single byte ranges, caps clients at eight, transfers 64 KiB chunks, and closes each connection within 30 seconds. Receiver connectivity, IPv6-only LANs, host local-network permissions, background execution, and physical AirPlay routing are separate integration concerns.

## Continuous live FLV and RTMP

`YlAirPlayLiveRemux.prepare(source:configuration:token:)` opens the production
sequential HTTP-FLV or RTMP input and returns once at least 18 seconds of independent
H.264/AAC-LC fMP4 segments are published. It never scans to EOF or seeks. Valid
FLV DTS/PTS are preserved, including B-frame composition offsets; each connection
starts at an IDR and normalizes its timeline into a distinct HLS period.

The retained media owns a worker independently of its completed load token.
Release cancels the upstream read immediately, closes the HLS listener, and queues
file removal after the producer and writer callbacks stop. Transient disconnects
retry at most three times, after 0.5/1/2 seconds. Every replacement connection gets
a new init map and discontinuity. The unfinished tail of a disconnected period is
discarded; published complete segments remain available through their retention
window. Invalid codecs, changed sequence headers, malformed FLV and timestamp
regressions are terminal and replay to the active backend's failure observer.

Bounds: 45 seconds to prepare the initial window; 8 MiB per FLV tag/packet; 64 KiB per
sequence-header configuration; less than 192 KiB retained by the streaming FLV
validator; 32 MiB per current segment; at most three flushed segments waiting for
writer callbacks, with a 5 second drain timeout. Segments begin at keyframes after
at least 2 seconds and may not span more than 6 seconds; audio/video may not drift
more than 6 seconds. HTTP connect/read waits are capped at 15 seconds and RTMP uses
its existing bounded transport deadlines. These are package payload bounds;
AVFoundation's internal memory remains opaque. The live store separately caps
resources at 128 MiB/128 files, keeps approximately 30 seconds in the playlist, uses a
constant 6 second target duration, and retains expired files long enough for clients
holding an earlier playlist. An open HTTP resource retains its accounted lease
until close, including after expiry.

Start the local fixture in one terminal (bind permission is required):

```sh
python3 tool/airplay/live_remux_fixture.py --port 18095
```

In another terminal, compile **all production Apple Swift sources**, open the real
network/demux/mux path, and verify AVPlayer readiness and decoded video while the
FLV socket stays open:

```sh
python3 tool/airplay/live_remux_check.py --output /tmp/yl-airplay-live-check \
  --reconnect http://127.0.0.1:18095/live.flv
/tmp/yl-airplay-live-check http://127.0.0.1:18095/aac-change.flv --expect-config-error
/tmp/yl-airplay-live-check http://127.0.0.1:18095/h264-change.flv --expect-config-error
python3 tool/airplay/live_remux_validator_check.py
```

The compiler harness defaults to `$HOME/flutter`; pass `--flutter-sdk` when needed.
The fixture repeats the repository's real H.264/AAC FLV with advancing timestamps,
initially bursts enough media for readiness, then paces subsequent epochs. The
existing fixture contains B-frames. Its `/disconnect` endpoint atomically closes
the original stream and returns an upper bound for every video PTS sent, including
packets still buffered downstream. The reconnect check requires the returned pixel buffer’s actual display timestamp
beyond that boundary on the same AVPlayerItem, alongside the replacement init map.
Other checks cover cancellation of an obsolete load token, zero bridge packets
following teardown, AAC/H.264 sequence-header change rejection, parser reads split
at 1/7/1024/32768 bytes, early oversized-tag rejection and refusal to rewind the
sequential parser. The pure validator check needs no listening socket.

The native `YlAirPlayHostTests` additionally cover real RTMP readiness before EOF,
HTTP rolling playlists/reconnect, stop/candidate cancellation, same-item lifetime,
and producer failure fencing. Standard live HLS retains its direct path. Physical
AirPlay receiver playback, route handoff and CarPlay remain separate device checks.
