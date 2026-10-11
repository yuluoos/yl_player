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

## External text subtitles (opt-in)

Create the controller with `enableTextSubtitles: true` to use the Dart-owned
external SRT/WebVTT runtime on Android, iOS or macOS. `YlPlayerView` then draws
selected subtitles over ordinary video without an extra widget:

```dart
final player = await YlPlayerController.create(enableTextSubtitles: true);
final session = await player.load(const YlFileSource('/absolute/video.mp4'));
await session.replaceExternalSubtitles([
  const YlExternalSubtitle(
    id: 'english',
    source: YlFileSource('/absolute/english.srt'),
    format: YlSubtitleFormat.srt,
    language: 'en',
  ),
]);
await session.selectSubtitleTrack('english');
await session.setSubtitleOffset(const Duration(milliseconds: 500)); // Delay.
// Build YlPlayerView(controller: player) in the widget tree.
await session.selectSubtitleTrack(null); // Immediately hide subtitles.
// Dispose the controller when its owning widget is removed.
```

Use `YlNetworkSource` for HTTP(S), including separately scoped credentials.
Both network policies are supported. `platformDefault` uses a 30-second total
read deadline, five redirects and no automatic retries. For
`networkPolicy: const YlNetworkPolicy.managed()`, the defaults are 10 seconds
through response headers, 15 seconds of body inactivity, three retries,
500 ms exponential backoff capped at 8 seconds, and five redirects across all
attempts. Nonempty body chunks reset only the read deadline; managed requests
have no total-call timeout. Valid `Retry-After` seconds or HTTP dates override
backoff within its cap; excessive values stop retries. TLS/certificate errors,
permanent HTTP errors, unsupported encodings, oversized input and parse errors
are never retried. Cancelling a session or replacement also cancels backoff.
Cross-origin redirects permanently strip credentials, including retries and a
later return to the original origin. File/HTTP input is streamed within a
4 MiB aggregate catalog budget, with at most 10,000 cues and bounded text spans.

Replacing the catalog is atomic; a failed download or parse leaves the previous
catalog usable and reports a sanitized `YlPlayerException`. A newer replacement,
load, stop or dispose cancels pending I/O. New sessions reset subtitles and offset.
In this opt-in mode, event `revision` identifies the public snapshot at delivery;
`occurredAt` retains the original event time. This avoids mixing native revisions
with locally published subtitle state.
Selection starts off; `[]` removes all external entries. Same-ID replacement
updates content while preserving current selection. Positive offsets delay cues.

Rendering supports plain UTF-8 text, balanced `b`/`i`/`u` markup, common entities,
and horizontal WebVTT position/align settings. Unsupported markup is rejected.
Cue timing follows published media positions, so precision depends on
`YlPlayerOptions.positionUpdateInterval`; no independent timer advances captions
while paused or buffering. Seek hides text until a post-ACK position snapshot.
Text stays upright in the visible video aperture after fit, crop, PAR and rotation.

This opt-in owns the external catalog and cannot be combined with a native
subtitle SPI. It does not support embedded tracks, TTML, ASS/SSA, PGS/VobSub,
WebVTT CSS/regions/karaoke, or protected video overlays. HDR subtitle brightness
and native-device synchronization remain unqualified. Without the opt-in, the
existing native capability/SPI gates continue to apply.
