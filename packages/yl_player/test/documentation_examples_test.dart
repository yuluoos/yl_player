import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'support/fake_player_platform.dart';

void main() {
  test(
    'README lifecycle runs through replacement, Stop, and Dispose',
    () async {
      final backend = FakePlatformPlayer();
      final lifecycle = documentedVideoLifecycle(
        Uri.parse('https://media.example/video.mp4'),
        platform: FakePlayerPlatform(backend),
      );

      await _waitFor(() => backend.loads.length == 1);
      backend.commit(const YlPlaybackSessionId('first'));
      backend.emit(status: YlPlaybackStatus.ready);
      backend.emitFirstFrame(const YlPlaybackSessionId('first'));

      await _waitFor(() => backend.loads.length == 2);
      backend.commit(const YlPlaybackSessionId('replacement'), index: 1);

      await lifecycle;
      expect(backend.calls, ['play', 'seekTo', 'play', 'stop']);
      expect(backend.disposeCount, 1);
    },
  );
}

/// Kept in step with the lifecycle example in packages/yl_player/README.md.
Future<void> documentedVideoLifecycle(
  Uri uri, {
  YlPlayerPlatform? platform,
  bool expectVideo = true,
}) async {
  final player = await YlPlayerController.create(
    options: const YlPlayerOptions(
      decoderPolicy: YlDecoderPolicy.hardwarePreferred,
      audioPolicy: YlAudioPolicy.appManaged,
    ),
    platform: platform,
  );
  try {
    final source = YlNetworkSource(
      uri,
      intent: YlStreamIntent.onDemand,
      format: YlMediaFormat.mp4,
      request: YlHttpRequest(headers: const {'User-Agent': 'yl-player-demo'}),
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

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100 && !predicate(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(predicate(), isTrue);
}
