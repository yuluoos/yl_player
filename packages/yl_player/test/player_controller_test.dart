import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/player_controller.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'support/fake_player_platform.dart';

void main() {
  test('explicit creation exposes capabilities and attaches streams', () async {
    final backend = FakePlatformPlayer();
    final platform = FakePlayerPlatform(backend);
    final player = await YlPlayerController.create(platform: platform);
    expect(player.capabilities, backend.capabilities);
    expect(player.implementationName, 'fake');
    expect(player.state.status, YlPlaybackStatus.idle);
    expect(player.textureId.value, 42);
    expect(platform.createCount, 1);
    expect(backend.stateController.hasListener, isTrue);
    expect(backend.eventController.hasListener, isTrue);
    await player.dispose();
  });
  test(
    'equal and older revisions notify nobody and disposed callbacks stay inert',
    () async {
      final backend = FakePlatformPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      var notices = 0;
      final snapshots = <YlPlayerState>[];
      player.addListener(() => notices++);
      final subscription = player.states.listen(snapshots.add);
      backend.emitState(YlPlayerState(revision: 2));
      backend.emitState(YlPlayerState(revision: 2));
      backend.emitState(YlPlayerState(revision: 1));
      expect(notices, 1);
      expect(snapshots, hasLength(1));
      backend.disposeError = StateError("broken backend keeps sending");
      await player.dispose();
      backend.emitState(YlPlayerState(revision: 3));
      expect(notices, 1);
      expect(player.state.revision, 2);
      await subscription.cancel();
      await backend.stateController.close();
      await backend.eventController.close();
    },
  );
  test('create returns failures and disposes incompatible backend', () async {
    final backend = FakePlatformPlayer();
    final platform = FakePlayerPlatform(backend);
    backend.implementation = const YlPlatformImplementationInfo(
      name: 'bad',
      version: '1',
      spiMajor: 1,
    );
    await expectLater(
      YlPlayerController.create(platform: platform),
      throwsA(
        isA<YlPlayerException>().having(
          (e) => e.failure.code,
          'code',
          YlFailureCodes.platformIncompatible,
        ),
      ),
    );
    expect(backend.disposeCount, 1);
    platform.createError = StateError('create failure');
    await expectLater(
      YlPlayerController.create(platform: platform),
      throwsStateError,
    );
  });
  test('invalid initial state disposes backend', () async {
    final backend = FakePlatformPlayer()
      ..currentState = YlPlayerState(status: YlPlaybackStatus.playing);
    await expectLater(
      YlPlayerController.create(platform: FakePlayerPlatform(backend)),
      throwsArgumentError,
    );
    expect(backend.disposeCount, 1);
  });
  test(
    'volume without session, identical disposal, texture null on cleanup failure',
    () async {
      final backend = FakePlatformPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      await player.setVolume(.2);
      expect(backend.calls, ['setVolume']);
      backend.disposeError = StateError('failed cleanup');
      final dispose = player.dispose();
      expect(identical(dispose, player.dispose()), isTrue);
      await dispose;
      expect(player.textureId.value, isNull);
      await expectLater(
        player.setVolume(.5),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.playerDisposed,
          ),
        ),
      );
    },
  );
}
