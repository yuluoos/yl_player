# yl_player platform interface v0.2

Requires Dart 3.12 and Flutter 3.44. `yl_player_platform_interface.dart` contains
immutable domain values, release validators, and the v2 handwritten platform
SPI. Applications import `package:yl_player/yl_player.dart`, whose explicit
exports exclude registration, backend interfaces, transport and validators.

Implement `YlPlayerPlatform.createPlayer(YlPlayerOptions)` and return a
`YlPlatformPlayer` with validated initial state/capabilities and implementation
identity (`spiMajor: ylPlayerSpiMajor`). Attach native streams before returning.
`load` returns `YlPlatformLoadResult` only after native commit and its correlated
authoritative state are both accepted. Ready and First Frame are separate.
State revisions increase across sessions. Session commands reject stale IDs;
volume, Stop and Dispose are player-owned. Command rejection does not fabricate
state/events. Dispose is idempotent and releases resources after failures too.

Use `testing.dart` for the reusable observable conformance suite.
`yl_player_legacy_transport.dart` is a private development migration entrypoint
for endorsed packages only and is removed before publication. Its native wire
remains protocol 1, with temporary `requestState` and candidate-owned `loadToken`
metadata to provide creation and Load barriers. It rejects strict managed network,
bounded buffer and hardware-required policies, and rejects plugin-managed audio
at creation. Apple controlled HLS carries explicit source-origin credentials;
opaque routes reject credentials. Decoder selection and unversioned events retain
legacy limitations documented in the app package README; this bridge is not a
strict-policy implementation.
