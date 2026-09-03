# yl_player_android

Endorsed Android implementation package for `yl_player`.

Version `0.1.0-dev.1` provides a Media3 1.11.0 ExoPlayer backend that renders
directly to a Flutter Texture. It targets Android 7.0 (API 24) or later and
supports local files, content URIs, HLS, HTTP-FLV, and Media3 progressive
containers subject to the device's MediaCodec support.

The backend applies bounded buffering, disables subtitle tracks, supports
request headers, live-edge seeking, audio-track selection, adaptive quality
ceilings, structured errors, and idempotent native resource release. The
`hardwareOnly` policy filters video decoders to hardware codecs; the default
`preferHardware` policy lets Media3 use its normal platform ordering and
fallback behavior.

Applications should depend on `yl_player`; Flutter selects this package on
Android automatically.

Low-end-device smoothness depends on stream codec/profile, resolution, bitrate,
and vendor decoder quality. Validate production streams on the actual device
matrix; a successful capability query is not a decoder-initialization promise.
