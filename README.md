# yl_player

`yl_player` is a federated Flutter playback kernel for Android, iOS, and
macOS. The v0.2 development API separates a long-lived player from replaceable
playback sessions, keeps rendering texture-only, and makes network, buffer,
decoder, and audio ownership requirements explicit.

The workspace requires Dart 3.12 and Flutter 3.44. Applications depend on
[`yl_player`](packages/yl_player/README.md); Flutter selects the endorsed
[`yl_player_android`](packages/yl_player_android/README.md) or
[`yl_player_apple`](packages/yl_player_apple/README.md) implementation. Platform
authors use the
[`yl_player_platform_interface`](packages/yl_player_platform_interface/README.md).

Start with the [application API and lifecycle](packages/yl_player/README.md).
Before adopting v0.2, read the [migration guide](docs/migration-to-0.2.md),
[platform support matrix](docs/platform-support.md), [policy semantics](docs/policies.md),
and [diagnostics contract](docs/diagnostics.md).

This is `0.2.0-dev.1`. Final physical-device, endurance, profiling, consumer,
and release acceptance remains pending; the support matrix distinguishes
implemented automated evidence from physical evidence.

The project is BSD-3-Clause licensed. The Android and Apple packages redistribute
minimized LGPL-2.1-or-later FFmpeg components for demuxing; Android additionally
uses its replaceable component for bounded software decoding. Keep each package's
license text, notices, replacement scripts, and artifact lock with binary
distributions.
