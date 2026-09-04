# yl_player_android

Endorsed Android implementation package for `yl_player`.

Version `0.1.0-dev.1` provides a Media3 1.11.0 ExoPlayer backend that renders
directly to a Flutter Texture. It targets Android 7.0 (API 24) or later and
supports local files, content URIs, HLS, HTTP-FLV, and Media3 progressive
containers subject to the device's MediaCodec support.

The backend automatically classifies a device as `constrained`, `standard`, or
`capable` from RAM, ABI, Android API level, and display size. Android video is
always hardware-only: software video decoders are rejected even when the public
configuration requests `preferHardware`. Audio decoders continue to use normal
Media3 selection. HEVC playback is available only when the device exposes a
compatible hardware decoder.

For the automatic buffer mode, constrained devices use these upper bounds:

| Source | Buffer duration | Byte ceiling |
| --- | --- | ---: |
| Local file/content URI | 2–10 seconds | 16 MiB |
| Network VOD | 4–15 seconds | 24 MiB |
| HLS live | 6–12 seconds | 20 MiB |
| HTTP-FLV live | 2–5 seconds | 12 MiB |

The constrained video envelope is at most 1920×1080 at 30 fps and is tightened
to the connected display. This is a selection limit, not a smooth-playback
guarantee. Runtime health monitoring can only downgrade an adaptive rendition;
it never upgrades automatically. HLS catch-up is capped at 1.03×, while severe
live backlog uses bounded live-edge recovery or reconnect behavior.

Only one player owns an active Android video decoder. Running-low memory shrinks
the byte budget; critical memory or background/UI-hidden transitions save the
position and release playback resources. Foreground restore recreates the
Surface and resumes only when playback was previously intended. Audio focus and
becoming-noisy behavior are delegated to Media3 with a three-second transient
focus grace period.

`YlPlaybackMetrics` exposes nullable Android diagnostics through
`androidDeviceTier`, `targetBufferBytes`, `adaptiveDowngradeCount`,
`surfaceRebuildCount`, and `selectedVideoBitrate`.

Applications should depend on `yl_player`; Flutter selects this package on
Android automatically.

Subtitles, background audio, software video decoding, downloads, and persistent
media cache are intentionally outside this package. Low-end-device smoothness
still depends on stream codec/profile, bitrate, and vendor decoder quality.
Android 7.0 / 1.5 GB RAM / 32-bit ARM physical-device endurance validation is
deferred; a successful capability query is not a decoder-initialization promise.
