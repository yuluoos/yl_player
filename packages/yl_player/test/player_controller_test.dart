import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/fake_player_platform.dart';

void main() {
  late FakePlatformPlayer backend;

  setUp(() {
    backend = FakePlatformPlayer();
    YlPlayerPlatform.instance = FakePlayerPlatform(backend);
  });

  test('mirrors backend state and delegates open', () async {
    final controller = YlPlayerController();
    final source = YlMediaSource.file('/video.mp4');

    await controller.open(source);
    backend.emitState(
      YlPlayerState(
        status: YlPlaybackStatus.ready,
        duration: const Duration(minutes: 1),
      ),
    );

    expect(controller.state.status, YlPlaybackStatus.ready);
    expect(controller.state.duration, const Duration(minutes: 1));
    expect(backend.openedSource, same(source));
    await controller.dispose();
  });

  test('delegates the complete playback command surface', () async {
    final controller = YlPlayerController();
    const quality = YlQualityConstraint(maxHeight: 1080);

    await controller.play();
    await controller.pause();
    await controller.seekTo(const Duration(seconds: 12));
    await controller.seekToLiveEdge();
    await controller.setPlaybackSpeed(1.25);
    await controller.setVolume(0.75);
    await controller.selectAudioTrack('audio-zh');
    await controller.setQualityConstraint(quality);

    expect(backend.calls, <String>[
      'play',
      'pause',
      'seekTo',
      'seekToLiveEdge',
      'setPlaybackSpeed',
      'setVolume',
      'selectAudioTrack',
      'setQualityConstraint',
    ]);
    expect(backend.seekPosition, const Duration(seconds: 12));
    expect(backend.playbackSpeed, 1.25);
    expect(backend.volume, 0.75);
    expect(backend.audioTrackId, 'audio-zh');
    expect(backend.qualityConstraint, same(quality));
    await controller.dispose();
  });

  test('dispose is idempotent and rejects later commands', () async {
    final controller = YlPlayerController();

    await controller.dispose();
    await controller.dispose();

    expect(backend.disposeCount, 1);
    await expectLater(controller.play(), throwsStateError);
  });

  test('command errors update state and emit an error event', () async {
    const error = YlPlayerError(
      category: YlPlayerErrorCategory.decoderUnsupported,
      code: 'decoder.unsupported',
      message: 'Unsupported stream.',
    );
    backend.playError = error;
    final controller = YlPlayerController();
    final emittedEvents = <YlPlayerEvent>[];
    final subscription = controller.events.listen(emittedEvents.add);

    await expectLater(controller.play(), throwsA(same(error)));

    expect(controller.state.status, YlPlaybackStatus.error);
    expect(controller.state.error, same(error));
    expect(emittedEvents.single, isA<YlErrorEvent>());

    await subscription.cancel();
    await controller.dispose();
  });

  test('does not duplicate an error already emitted by the backend', () async {
    const error = YlPlayerError(
      category: YlPlayerErrorCategory.network,
      code: 'network.timeout',
      message: 'Timed out.',
    );
    backend
      ..playError = error
      ..emitPlayErrorBeforeThrow = true;
    final controller = YlPlayerController();
    final emittedEvents = <YlPlayerEvent>[];
    final subscription = controller.events.listen(emittedEvents.add);

    await expectLater(controller.play(), throwsA(same(error)));

    expect(emittedEvents, hasLength(1));

    await subscription.cancel();
    await controller.dispose();
  });

  test('does not mirror stale backend callbacks after dispose', () async {
    final controller = YlPlayerController();
    final emittedStates = <YlPlayerState>[];
    final subscription = controller.states.listen(emittedStates.add);

    await controller.dispose();
    backend.emitState(YlPlayerState(status: YlPlaybackStatus.playing));
    await Future<void>.delayed(Duration.zero);

    expect(
      emittedStates.where((state) => state.status == YlPlaybackStatus.playing),
      isEmpty,
    );
    await subscription.cancel();
  });

  test('cleans up Dart resources when backend disposal fails', () async {
    final controller = YlPlayerController();
    final emittedStates = <YlPlayerState>[];
    final subscription = controller.states.listen(emittedStates.add);
    backend.disposeError = StateError('native dispose failed');

    await controller.dispose();
    backend.emitState(YlPlayerState(status: YlPlaybackStatus.playing));
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.status, YlPlaybackStatus.disposed);
    expect(backend.disposeCount, 1);
    expect(
      emittedStates.where((state) => state.status == YlPlaybackStatus.playing),
      isEmpty,
    );
    await subscription.cancel();
  });
}
