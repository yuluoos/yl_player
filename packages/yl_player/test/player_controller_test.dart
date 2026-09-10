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

  test(
    'presentation cache accepts one delayed current-session milestone and resets on replacement',
    () async {
      final backend = FakePlatformPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      const first = YlPlaybackSessionId('first');
      const second = YlPlaybackSessionId('second');
      final loading = player.load(_source);
      _publishSession(backend, first);
      backend.emit(status: YlPlaybackStatus.playing);
      var notices = 0;
      player.addListener(() => notices++);

      backend.emitFirstFrame(first, revision: 1);
      expect(player.isCurrentFramePresented, isTrue);
      expect(notices, 1);
      backend.emitFirstFrame(first, revision: 1);
      backend.emitFirstFrame(second);
      expect(player.isCurrentFramePresented, isTrue);
      expect(notices, 1);

      backend.loads.single.complete(
        const YlPlatformLoadResult(sessionId: first),
      );
      final session = await loading;
      await session.firstFrame;
      _publishSession(backend, second);
      expect(player.isCurrentFramePresented, isFalse);
      expect(notices, 2);

      backend.emitFirstFrame(first);
      expect(player.isCurrentFramePresented, isFalse);
      expect(notices, 2);
      await player.dispose();
    },
  );

  test('failed current session clears presentation cache', () async {
    final backend = FakePlatformPlayer();
    final player = await YlPlayerController.create(
      platform: FakePlayerPlatform(backend),
    );
    const sessionId = YlPlaybackSessionId('failed');
    final loading = player.load(_source);
    _publishSession(backend, sessionId);
    backend.loads.single.complete(
      const YlPlatformLoadResult(sessionId: sessionId),
    );
    await loading;
    backend.emitFirstFrame(sessionId);
    expect(player.isCurrentFramePresented, isTrue);

    backend.emit(status: YlPlaybackStatus.failed, failure: _failure.failure);
    expect(player.isCurrentFramePresented, isFalse);
    await player.dispose();
  });

  test('disposal clears presentation cache with one notification', () async {
    final backend = FakePlatformPlayer();
    final player = await YlPlayerController.create(
      platform: FakePlayerPlatform(backend),
    );
    const sessionId = YlPlaybackSessionId('disposed');
    final loading = player.load(_source);
    _publishSession(backend, sessionId);
    backend.loads.single.complete(
      const YlPlatformLoadResult(sessionId: sessionId),
    );
    await loading;
    backend.emitFirstFrame(sessionId);
    var notices = 0;
    player.addListener(() => notices++);

    await player.dispose();
    expect(player.isCurrentFramePresented, isFalse);
    expect(notices, 1);
  });

  test(
    'accepted Stop clears presentation but rejected Stop preserves it',
    () async {
      final backend = FakePlatformPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      const sessionId = YlPlaybackSessionId('playing');
      final loading = player.load(_source);
      _publishSession(backend, sessionId);
      backend.loads.single.complete(
        const YlPlatformLoadResult(sessionId: sessionId),
      );
      await loading;
      backend.emitFirstFrame(sessionId);
      var notices = 0;
      player.addListener(() => notices++);

      backend.stopError = _failure;
      await expectLater(player.stop(), throwsA(same(_failure)));
      expect(player.isCurrentFramePresented, isTrue);
      expect(notices, 0);

      backend.stopError = null;
      backend.emitIdleOnStop = false;
      await player.stop();
      expect(player.state.sessionId, sessionId);
      expect(player.isCurrentFramePresented, isFalse);
      expect(notices, 1);
      await player.dispose();
    },
  );
}

final _source = YlNetworkSource(Uri.parse('https://example.test/video.mp4'));
const _failure = YlPlayerException(
  YlFailure(
    category: YlFailureCategory.decoder,
    code: YlFailureCodes.decoderUnavailable,
    message: 'Unavailable.',
    retryable: false,
    scope: YlFailureScope.session,
    diagnosticId: 'view-test',
  ),
);

void _publishSession(
  FakePlatformPlayer backend,
  YlPlaybackSessionId sessionId,
) {
  backend.emitState(
    YlPlayerState(
      revision: backend.state.revision + 1,
      sessionId: sessionId,
      status: YlPlaybackStatus.loading,
      videoGeometry: const YlVideoGeometry(
        encodedSize: YlPixelSize(1920, 1080),
        displaySize: YlPixelSize(1920, 1080),
      ),
    ),
  );
}
