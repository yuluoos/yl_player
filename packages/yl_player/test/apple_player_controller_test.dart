// Consumer integration intentionally imports the Apple package's private
// adapter/transport/schema: no test hooks or DTOs are exported by public APIs.
// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_apple/src/apple_player.dart';
import 'package:yl_player_apple/src/apple_transport.dart';
import 'package:yl_player_apple/src/pigeon/yl_player_apple.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  test(
    'prepared state and geometry do not resolve firstFrame before its native publication callback',
    () async {
      final native = _Native();
      final controller = await _controller(native);
      addTearDown(controller.dispose);
      final session = await _commit(controller, native);
      await session.ready;
      var firstFrame = false;
      unawaited(
        session.firstFrame.then((_) {
          firstFrame = true;
        }, onError: (Object _) {}),
      );
      native.callbacks!.onState(
        _state(
            session: 's1',
            revision: 2,
            sequence: 2,
            status: ApplePlaybackStatus.playing,
          )
          ..geometry = AppleVideoGeometryMessage(
            encodedSize: AppleSizeMessage(width: 1920, height: 1080),
            displaySize: AppleSizeMessage(width: 1920, height: 1080),
            pixelAspectRatio: 1,
            rotationDegrees: 0,
          ),
      );
      await _flush();
      expect(controller.state.videoGeometry, isNotNull);
      expect(firstFrame, isFalse);
      native.callbacks!.onFirstFrame(
        AppleFirstFrameMessage(
          sessionId: 'obsolete',
          revision: 2,
          sequence: 3,
          occurredAtMs: 10,
        ),
      );
      await _flush();
      expect(firstFrame, isFalse);
      // This verifies the Dart publication boundary only. Task 7 proves that the
      // native callback is emitted by actual committed private-texture publication.
      native.callbacks!.onFirstFrame(
        AppleFirstFrameMessage(
          sessionId: 's1',
          revision: 2,
          sequence: 4,
          occurredAtMs: 11,
        ),
      );
      await session.firstFrame;
      expect(firstFrame, isTrue);
      expect(controller.state.metrics.loadToFirstFrame, isNull);
    },
  );
  for (final action in ['stop', 'dispose', 'replace', 'failure']) {
    test(
      'controller firstFrame is settled by $action and late callbacks cannot revive it',
      () async {
        final native = _Native();
        final controller = await _controller(native);
        addTearDown(controller.dispose);
        final session = await _commit(controller, native);
        final callbacks = native.callbacks!;
        final code = switch (action) {
          'dispose' => YlFailureCodes.playerDisposed,
          'failure' => YlFailureCodes.networkFailed,
          _ => YlFailureCodes.sessionStale,
        };
        final failure = expectLater(
          session.firstFrame,
          throwsA(
            isA<YlPlayerException>().having(
              (error) => error.failure.code,
              'code',
              code,
            ),
          ),
        );
        switch (action) {
          case 'stop':
            await controller.stop();
          case 'dispose':
            await controller.dispose();
          case 'replace':
            await _commit(controller, native, session: 's2', revision: 2);
          case 'failure':
            callbacks.onState(
              _state(
                  session: 's1',
                  revision: 2,
                  sequence: 2,
                  status: ApplePlaybackStatus.failed,
                )
                ..failure = AppleFailureMessage(
                  category: AppleFailureCategory.network,
                  code: YlFailureCodes.networkFailed,
                  message: 'private',
                  retryable: false,
                  scope: AppleFailureScope.session,
                  diagnosticId: 'native-failure',
                ),
            );
        }
        await failure;
        callbacks.onFirstFrame(
          AppleFirstFrameMessage(
            sessionId: 's1',
            revision: 2,
            sequence: 3,
            occurredAtMs: 12,
          ),
        );
        await _flush();
        await expectLater(
          session.firstFrame,
          throwsA(
            isA<YlPlayerException>().having(
              (error) => error.failure.code,
              'code',
              code,
            ),
          ),
        );
      },
    );
  }
  for (final atMaximum in [false, true]) {
    test(
      'real controller settles terminal firstFrame before blocked disposal: maximum=$atMaximum',
      () async {
        final native = _Native();
        final release = Completer<void>();
        native.disposal = release.future;
        final controller = await _controller(native);
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await controller.dispose();
        });
        final revision = atMaximum ? 0x7fffffffffffffff : 10;
        final session = await _commit(controller, native, revision: revision);
        final milestone = expectLater(
          session.firstFrame,
          throwsA(
            isA<YlPlayerException>().having(
              (error) => error.failure.code,
              'code',
              atMaximum
                  ? YlFailureCodes.protocolMismatch
                  : YlFailureCodes.platformUnavailable,
            ),
          ),
        );
        native.volumeFailure = PlatformException(code: 'channel-error');
        await expectLater(
          controller.setVolume(.5),
          throwsA(isA<YlPlayerException>()),
        );
        await _flush();
        await milestone;
        expect(native.disposeStarted, isTrue);
        expect(release.isCompleted, isFalse);
        if (!atMaximum) {
          expect(controller.state.revision, revision + 1);
          expect(controller.state.status, YlPlaybackStatus.failed);
        }
        release.complete();
      },
    );
  }

  for (final finalStatus in [
    ApplePlaybackStatus.buffering,
    ApplePlaybackStatus.paused,
  ]) {
    for (final frameBeforeReady in [false, true]) {
      test(
        'real controller receives retained READY with null metrics and ordered callbacks: $finalStatus frameBeforeReady=$frameBeforeReady',
        () async {
          final native = _Native();
          final controller = await _controller(native);
          addTearDown(controller.dispose);
          final chronology = <String>[];
          final revisions = <int>[];
          final states = controller.states.listen((state) {
            revisions.add(state.revision);
            chronology.add('state:${state.status.name}');
          });
          final events = controller.events.listen((event) {
            if (event is YlFirstFrameEvent) chronology.add('frame');
            if (event is YlPlaybackEngineChangedEvent) chronology.add('engine');
          });
          addTearDown(states.cancel);
          addTearDown(events.cancel);
          final loading = controller.load(_source);
          await _flush();
          native.callbacks!.onState(
            _state(
              session: 's1',
              revision: 1,
              sequence: 1,
              status: ApplePlaybackStatus.loading,
            ),
          );
          if (frameBeforeReady) {
            native.callbacks!.onFirstFrame(
              AppleFirstFrameMessage(
                sessionId: 's1',
                revision: 1,
                sequence: 2,
                occurredAtMs: 10,
              ),
            );
          }
          native.callbacks!.onState(
            _state(
              session: 's1',
              revision: 2,
              sequence: frameBeforeReady ? 3 : 2,
              status: ApplePlaybackStatus.ready,
            ),
          );
          if (!frameBeforeReady) {
            native.callbacks!.onFirstFrame(
              AppleFirstFrameMessage(
                sessionId: 's1',
                revision: 2,
                sequence: 3,
                occurredAtMs: 10,
              ),
            );
          }
          native.callbacks!.onState(
            _state(
              session: 's1',
              revision: 3,
              sequence: 4,
              status: finalStatus,
            ),
          );
          native.callbacks!.onEngineChanged(
            AppleEngineChangedMessage(
              sessionId: 's1',
              revision: 3,
              sequence: 5,
              occurredAtMs: 11,
              previousEngine: AppleEngine.unknown,
              engine: AppleEngine.avPlayer,
            ),
          );
          expect(
            chronology,
            isEmpty,
            reason: 'The native Load reply has not committed the candidate.',
          );
          native.loadReply.complete(
            AppleLoadReply(
              loadRequestId: native.request!.loadRequestId,
              sessionId: 's1',
            ),
          );
          final session = await loading;
          var ready = false, firstFrame = false;
          unawaited(
            session.ready.then((_) {
              ready = true;
            }, onError: (Object _) {}),
          );
          unawaited(
            session.firstFrame.then((_) {
              firstFrame = true;
            }, onError: (Object _) {}),
          );
          await _flush();
          expect(ready, isTrue);
          expect(firstFrame, isTrue);
          expect(controller.state.status.name, finalStatus.name);
          expect(controller.state.metrics.loadToReady, isNull);
          expect(controller.state.metrics.loadToFirstFrame, isNull);
          expect(chronology.where((value) => value.startsWith('state:')), [
            'state:loading',
            'state:ready',
            'state:${finalStatus.name}',
          ]);
          expect(revisions, [1, 2, 3]);
          expect(chronology.where((value) => !value.startsWith('state:')), [
            'frame',
            'engine',
          ]);
        },
      );
    }
  }
  for (final action in ['newLoad', 'stop', 'dispose']) {
    test(
      'controller $action from replay listener cancels the owned completion turn',
      () async {
        final native = _Native();
        final controller = await _controller(native);
        addTearDown(controller.dispose);
        Object? failure;
        var succeeded = false, triggered = false;
        final subscription = controller.states.listen((_) {
          if (triggered) return;
          triggered = true;
          switch (action) {
            case 'newLoad':
              unawaited(
                controller
                    .load(_source)
                    .then<void>((_) {}, onError: (Object _) {}),
              );
            case 'stop':
              unawaited(controller.stop());
            case 'dispose':
              unawaited(controller.dispose());
          }
        });
        addTearDown(subscription.cancel);
        final loading = controller
            .load(_source)
            .then<void>(
              (_) {
                succeeded = true;
              },
              onError: (Object error) {
                failure = error;
              },
            );
        await _flush();
        native.callbacks!.onState(
          _state(
            session: 's1',
            revision: 1,
            sequence: 1,
            status: ApplePlaybackStatus.ready,
          ),
        );
        native.callbacks!.onState(
          _state(
            session: 's1',
            revision: 2,
            sequence: 2,
            status: ApplePlaybackStatus.buffering,
          ),
        );
        native.loadReply.complete(
          AppleLoadReply(
            loadRequestId: native.request!.loadRequestId,
            sessionId: 's1',
          ),
        );
        await loading;
        await _flush();
        expect(triggered, isTrue);
        expect(succeeded, isFalse);
        expect(
          failure,
          isA<YlPlayerException>().having(
            (error) => error.failure.code,
            'code',
            action == 'dispose'
                ? YlFailureCodes.playerDisposed
                : YlFailureCodes.loadCancelled,
          ),
        );
        await _flush();
        expect(succeeded, isFalse);
      },
    );
  }
  test('real controller does not infer READY from initial BUFFERING', () async {
    final native = _Native();
    final controller = await _controller(native);
    addTearDown(controller.dispose);
    final loading = controller.load(_source);
    await _flush();
    native.callbacks!.onState(
      _state(
        session: 's1',
        revision: 1,
        sequence: 1,
        status: ApplePlaybackStatus.buffering,
      ),
    );
    native.loadReply.complete(
      AppleLoadReply(
        loadRequestId: native.request!.loadRequestId,
        sessionId: 's1',
      ),
    );
    final session = await loading;
    var ready = false;
    unawaited(
      session.ready.then((_) {
        ready = true;
      }, onError: (Object _) {}),
    );
    await _flush();
    expect(ready, isFalse);
    expect(controller.state.status, YlPlaybackStatus.loading);
  });
}

final _source = YlNetworkSource(Uri.parse('https://media.test/video'));
Future<void> _flush() => Future<void>.delayed(Duration.zero);

AppleStateMessage _state({
  String? session,
  int revision = 0,
  int sequence = 0,
  ApplePlaybackStatus status = ApplePlaybackStatus.idle,
}) => AppleStateMessage(
  loadRequestId: session == null ? null : 'load-${session.substring(1)}',
  sessionId: session,
  revision: revision,
  sequence: sequence,
  status: status,
  timeline: AppleTimelineMessage(
    positionMs: 0,
    bufferedPositionMs: 0,
    isSeekable: false,
    isLive: false,
  ),
  audioTracks: [],
  videoTracks: [],
  engine: AppleEngine.avPlayer,
  decoderMode: AppleDecoderMode.unknown,
  metrics: AppleMetricsMessage(),
);

Future<YlPlayerController> _controller(_Native native) async {
  final backend = await ApplePlayer.create(
    const YlPlayerOptions(),
    factory: _Factory(),
    transportForSuffix: (_) => native,
    setupCallbacks: (_, callbacks) {
      native.callbacks = callbacks;
    },
  );
  return YlPlayerController.create(platform: _Platform(backend));
}

final class _Platform extends YlPlayerPlatform {
  _Platform(this.backend);
  final YlPlatformPlayer backend;
  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerOptions options) async =>
      backend;
}

final class _Factory implements AppleFactoryTransport {
  @override
  Future<AppleCreateReply> create(AppleCreateRequest request) async =>
      AppleCreateReply(
        schemaMajor: 2,
        spiMajor: 2,
        platform: ApplePlatform.ios,
        channelSuffix: 'controller-test',
        textureId: 1,
        implementationName: 'apple-test',
        implementationVersion: 'test',
        capabilities: AppleCapabilitiesMessage(
          deviceProfile: 'apple',
          availableEngines: [AppleEngine.avPlayer],
          decoderEvidence: AppleDecoderEvidence.none,
          hardwareVideoCodecs: ['video/avc', 'video/hevc'],
          supportedOperations: [],
        ),
        initialState: _state(),
      );
}

/// Only native create/attach/assess/load/stop/dispose are needed by these consumers.
/// Unexpected commands fail instead of supplying placeholder success.
final class _Native implements ApplePlayerTransport {
  ApplePlayerFlutterApi? callbacks;
  AppleLoadRequest? request;
  final _replies = <Completer<AppleLoadReply>>[];
  Completer<AppleLoadReply> get loadReply => _replies.last;
  Future<void>? disposal;
  bool disposeStarted = false;
  Object? volumeFailure;
  @override
  Future<void> attach() async {}
  @override
  Future<AppleAssessmentReply> assess(AppleAssessRequest request) async =>
      AppleAssessmentReply(
        outcome: AppleAssessmentOutcome.compatible,
        satisfiedRequirements: [],
        limitations: [],
      );
  @override
  Future<AppleLoadReply> load(AppleLoadRequest request) {
    this.request = request;
    final reply = Completer<AppleLoadReply>();
    _replies.add(reply);
    return reply.future;
  }

  @override
  Future<void> dispose() async {
    disposeStarted = true;
    await disposal;
  }

  @override
  Future<void> play(AppleSessionCommand command) => throw UnimplementedError();
  @override
  Future<void> pause(AppleSessionCommand command) => throw UnimplementedError();
  @override
  Future<void> seekTo(AppleSeekCommand command) => throw UnimplementedError();
  @override
  Future<void> seekToLiveEdge(AppleSessionCommand command) =>
      throw UnimplementedError();
  @override
  Future<void> setPlaybackSpeed(AppleSpeedCommand command) =>
      throw UnimplementedError();
  @override
  Future<void> selectAudioTrack(AppleTrackCommand command) =>
      throw UnimplementedError();
  @override
  Future<void> setVideoConstraints(AppleVideoConstraintsCommand command) =>
      throw UnimplementedError();
  @override
  Future<void> setVolume(double volume) =>
      Future.error(volumeFailure ?? UnimplementedError());
  @override
  Future<void> stop() async {}
}

Future<YlPlaybackSession> _commit(
  YlPlayerController controller,
  _Native native, {
  String session = 's1',
  int revision = 1,
}) async {
  final loading = controller.load(_source);
  await _flush();
  native.callbacks!.onState(
    _state(
      session: session,
      revision: revision,
      sequence: revision,
      status: ApplePlaybackStatus.ready,
    ),
  );
  native.loadReply.complete(
    AppleLoadReply(
      loadRequestId: native.request!.loadRequestId,
      sessionId: session,
    ),
  );
  return loading;
}
