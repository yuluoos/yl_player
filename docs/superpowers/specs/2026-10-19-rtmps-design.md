# RTMPS live and AirPlay

The user requests implementing the RTMPS extension discussed immediately before
this task. Extend the existing Apple RTMP transport for ordinary live playback
and the AirPlay remux path. Keep iOS 15/macOS 12 and the shipped FFmpeg binary.

## Decisions

- Reuse Network.framework TCP/TLS, the RTMP handshake/parser, FLV demux and HLS
  live producer. RTMP stays plaintext/default1935; RTMPS uses TLS/default443.
  Explicit valid ports, original tcUrl, query/playpath and URI limits survive.
- TLS requires peer authentication, hostname/SNI and system trust, minimum1.2.
  No public trust bypass, custom-CA API, client certificates or downgrade to RTMP.
  Test-only local certificate anchors retain real chain/hostname evaluation.
- TLS errors are terminal `network.rtmp_tls_failed`, safe public diagnostics,
  nonrecoverable and excluded from both ordinary and AirPlay retry budgets.
  TCP disconnect/timeouts retain existing bounded recovery. Setup deadlines and
  cancellation cover TLS handshake and RTMP handshake together.
- Both ordinary and AirPlay assessment admit valid RTMPS sources with existing
  policy/codec restrictions. Automatic format becomes FLV/live before AirPlay
  inspection. H.264 with optional mono/stereo AAC-LC remains the live bridge scope.
- Source encryption applies upstream; generated AirPlay HLS retains its current
  temporary LAN HTTP origin and startup/window/storage limits.
- Verify actual encrypted RTMP handshake/media and demux; untrusted certificate,
  hostname mismatch, cancellation during TLS setup, reconnect and AirPlay output.
  No system keychain/trust-store mutations; fixtures remain test-only.
- No Android capability expansion, Pigeon change, transcoding or public API change.
  Physical receivers/CarPlay remain unverified. Do not auto-commit new work.
