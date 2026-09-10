# yl_player_android

Endorsed Android implementation for `yl_player` 0.2. Applications should depend
on `yl_player`; Flutter registers this package automatically. It targets Android
7.0/API 24 or later and uses Media3 1.11.0 with a Flutter texture.

The Media3 route accepts local files, Android content URIs, HLS, HTTP-FLV, and
progressive containers subject to extractor, codec, device, and server support.
Both platform-default and Android managed networking are implemented with
same-origin credential enforcement. Exact managed timeout/retry behavior is
documented in the repository [policy guide](../../docs/policies.md). Exact
bounded-buffer requests are rejected; built-in buffer strategies remain tuning
goals.

Decoder policies are honored per Player with an optional per-Load override.
System-default retains the Media3 order, hardware-preferred ranks hardware but
retains fallbacks, and hardware-required filters candidates and verifies the
initialized MediaCodec for video. A capability snapshot is conservative and
does not prove that a codec will initialize for arbitrary media.

Plugin-managed audio uses one focus owner and preserves current playback intent
through replacement, transient focus loss, foreground reconstruction, Stop,
and Dispose. App-managed audio leaves focus decisions to the application. One
active Android video decoder lease is granted at a time; memory and lifecycle
events can quiesce and reconstruct the active session.

The implementation exposes Media3 state, tracks, geometry, decoder mode,
metrics, correlated events, and safe `YlFailure` values through the v0.2 SPI.
Subtitles, downloads, persistent media cache, and background audio are outside
the package. See the [support matrix](../../docs/platform-support.md) for route
limits and the outstanding physical Android endurance evidence.
