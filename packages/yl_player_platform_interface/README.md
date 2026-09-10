# yl_player_platform_interface v0.2

This package defines the immutable domain values, validators, and handwritten
SPI used by endorsed `yl_player` implementations. It requires Dart 3.12 and
Flutter 3.44. Applications should import `package:yl_player/yl_player.dart`;
that barrel intentionally excludes registration, backend, transport, testing,
and validation APIs.

A platform implementation subclasses `YlPlayerPlatform`, implements
`createPlayer(YlPlayerOptions)`, and returns a `YlPlatformPlayer` with validated
initial state, capabilities, texture identity, and
`YlPlatformImplementationInfo(spiMajor: ylPlayerSpiMajor)`. Attach native
callbacks before returning so no initial state or event can be lost.

`assess` is side-effect-free with respect to playback and returns compatible,
incompatible, or requires-inspection. `load` returns `YlPlatformLoadResult`
only after native commit and the correlated full state have both been accepted,
in either order. It does not wait for Ready or First Frame. State revisions
increase across sessions; every event carries the current session identity and
revision. A replaced or stopped identity must reject commands. Command
rejection must not fabricate state or events.

Session commands receive `YlPlaybackSessionId`. Volume, Stop, and Dispose are
player-owned. Stop preserves a reusable player. Dispose is idempotent,
terminates pending work, and releases resources even after failure. Public
failures use validated `YlFailure` metadata and never forward raw native
diagnostics.

Import `package:yl_player_platform_interface/testing.dart` for the reusable
observable conformance utilities. The application-facing lifecycle is
documented in the [`yl_player` README](../yl_player/README.md); exact policy and
diagnostic contracts are in the repository [policy guide](../../docs/policies.md)
and [diagnostics guide](../../docs/diagnostics.md).
