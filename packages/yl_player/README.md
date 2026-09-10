# yl_player v0.2 development API

`yl_player` is the application package. It requires Dart 3.12 and Flutter 3.44
and endorses Android, iOS, and macOS implementations. Version 0.2 is a breaking
cutover; there is no v0.1 compatibility shim.

## Lifecycle

Create one player during asynchronous startup or `initState`, never from
`build`. A Load returns a handle for one committed session. Ready and First
Frame are later, independent milestones. The following example is exercised by
`test/documentation_examples_test.dart`:

```dart
import 'package:yl_player/yl_player.dart';

Future<void> playVideo(Uri uri, {bool expectVideo = true}) async {
  final player = await YlPlayerController.create(
    options: const YlPlayerOptions(
      decoderPolicy: YlDecoderPolicy.hardwarePreferred,
      audioPolicy: YlAudioPolicy.appManaged,
    ),
  );
  try {
    final source = YlNetworkSource(
      uri,
      intent: YlStreamIntent.onDemand,
      format: YlMediaFormat.mp4,
      request: YlHttpRequest(
        headers: const {'User-Agent': 'yl-player-demo'},
      ),
    );
    final assessment = await player.assess(source);
    if (assessment.outcome == YlSourceAssessmentOutcome.incompatible) {
      throw YlPlayerException(assessment.rejection!);
    }

    final session = await player.load(
      source,
      options: const YlLoadOptions(
        bufferStrategy: YlBufferStrategy.automatic(),
      ),
    );
    await session.ready;
    await session.play();
    if (expectVideo) await session.firstFrame;
    await session.seekTo(const Duration(seconds: 10));

    final replacement = await player.load(source);
    try {
      await session.pause();
      throw StateError('The replaced session unexpectedly remained current.');
    } on YlPlayerException catch (error) {
      if (error.failure.code != YlFailureCodes.sessionStale) rethrow;
    }
    await replacement.play();
    await player.stop();
  } finally {
    await player.dispose();
  }
}
```

`assess` is decoder-free where possible. `compatible` means the known route and
requested policies can be enforced; it does not prove reachability, media
integrity, codec initialization, or runtime timing. `requiresInspection` means
Load must inspect the source before it can decide. Load can therefore still
fail after either non-incompatible result.

Load completes only after the candidate commits and its matching authoritative
state has been accepted. `session.ready` means decoder/media readiness.
`session.firstFrame` means a frame from that session reached the committed
public output. Do not await First Frame for audio-only media. A newer Load,
successful Stop, or Dispose makes the old handle fail locally with
`session.stale`; a rejected replacement or rejected Stop leaves the accepted
session usable.

Session commands are `play`, `pause`, `seekTo`, `seekToLiveEdge`,
`setPlaybackSpeed`, `selectAudioTrack`, and `setVideoConstraints`. Player-wide
commands are `setVolume`, `stop`, and `dispose`. Await or otherwise observe every
returned Future. Stop keeps the player and texture reusable; Dispose is
idempotent and terminal.

## Rendering and observation

```dart
YlPlayerView(
  controller: player,
  placeholder: const Center(child: CircularProgressIndicator()),
)
```

`YlPlayerView` contains no controls or application state. It defaults to a
centered `BoxFit.contain` texture on black and keeps the placeholder visible
until the current session's First Frame. Subscribe to `player.states`,
`player.events`, or the controller's `Listenable` notifications. State and
events are authoritative native observations; command rejection does not
invent either.

## Sources and policies

Use `YlFileSource`, `YlNetworkSource`, or Android-only
`YlAndroidContentSource`. `YlHttpRequest.headers` is ordinary metadata.
Authorization, cookies, API keys, tokens, and every other credential-bearing
value belongs in `credentials` so the origin policy can strip it permanently
after a cross-origin transition.

Player-wide decoder and audio ownership choices live in `YlPlayerOptions`.
Autoplay, start position, buffer strategy, video constraints, and an optional
decoder override live in `YlLoadOptions`. See the repository
[policy semantics](../../docs/policies.md), [support matrix](../../docs/platform-support.md),
and [diagnostics guide](../../docs/diagnostics.md).

## Errors

Public asynchronous failures are `YlPlayerException` values carrying a
`YlFailure`. Branch on stable category, code, retryability, and scope. Log the
opaque diagnostic ID for correlation. Do not log source locators or request
metadata. See [diagnostics](../../docs/diagnostics.md).
