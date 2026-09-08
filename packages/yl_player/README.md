# yl_player v0.2 development API

Requires Dart 3.12 and Flutter 3.44. This is a breaking development cutover.

```dart
import 'package:yl_player/yl_player.dart';

final player = await YlPlayerController.create();
final session = await player.load(
  YlNetworkSource(Uri.parse(url), intent: YlStreamIntent.onDemand),
  options: const YlLoadOptions(startPosition: Duration(seconds: 5)),
);
await session.play();
await session.ready;       // Decoder/media readiness, separate from Load commit.
await session.firstFrame;  // First frame on the committed public output.
await player.setVolume(0.5);
await player.stop();       // Keeps the player and texture reusable.
await player.dispose();
```

Create the player once in asynchronous startup or `initState`; never create it
from `build` or by reading texture/state. `YlPlayerView(controller: player)`
shows the native texture. Own and await disposal; Flutter `State.dispose` can
start an `unawaited` wrapper that awaits it.

Commands belong to the returned `YlPlaybackSession`. A replacement Load, Stop or
Dispose invalidates old handles locally. A failed candidate before commit leaves
the previous session usable. Load completes at the commit/state barrier; Ready
and First Frame remain independent futures. Command errors propagate as
`YlPlayerException` without inventing playback state or events. Player state and
events are authoritative native observations. Subscribe to `states`, `events`,
or the controller's `Listenable` interface for updates.

Sources are `YlNetworkSource`, `YlFileSource`, and `YlAndroidContentSource`.
`YlHttpRequest.headers` holds ordinary metadata; put Authorization, cookies and
all custom credential values in `credentials`. Public diagnostics exclude source
URIs, request metadata and native stacks.

The temporary protocol-1 bridge is removed before v0.2 publication. It currently
rejects managed network timing, bounded buffering, and hardware-required requests
with `policy.unsupported` before native open. Explicit
`pluginManagedMediaPlayback` is rejected before native create; default
`appManaged` leaves system audio ownership to the application. Built-in buffer
strategies are goals rather than strict bounds. Legacy fallback routes still
require hardware internally and may reject media despite the preferred/default
Dart decoder policy. Decoder mode is reported as unknown without verified native
evidence. The bridge accepts credentials on controlled Apple HLS routes only;
other credential-bearing routes are rejected before open. Unversioned native
first-frame/retry/failure events have temporary current-session correlation
limits; platform typed transports will remove these limitations.
