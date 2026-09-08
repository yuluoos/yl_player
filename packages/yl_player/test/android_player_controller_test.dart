// Consumer integration intentionally imports the Android package's private
// adapter/transport/schema: no test hooks or DTOs are exported by public APIs.
// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_android/src/android_player.dart';
import 'package:yl_player_android/src/android_transport.dart';
import 'package:yl_player_android/src/pigeon/yl_player_android.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  for (final finalStatus in [
    AndroidPlaybackStatus.buffering,
    AndroidPlaybackStatus.paused,
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
              status: AndroidPlaybackStatus.loading,
            ),
          );
          if (frameBeforeReady) {
            native.callbacks!.onFirstFrame(
              AndroidFirstFrameMessage(
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
              status: AndroidPlaybackStatus.ready,
            ),
          );
          if (!frameBeforeReady) {
            native.callbacks!.onFirstFrame(
              AndroidFirstFrameMessage(
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
            AndroidEngineChangedMessage(
              sessionId: 's1',
              revision: 3,
              sequence: 5,
              occurredAtMs: 11,
              previousEngine: AndroidEngine.unknown,
              engine: AndroidEngine.media3,
            ),
          );
          expect(
            chronology,
            isEmpty,
            reason: 'The native Load reply has not committed the candidate.',
          );
          native.loadReply.complete(
            AndroidLoadReply(
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
            status: AndroidPlaybackStatus.ready,
          ),
        );
        native.callbacks!.onState(
          _state(
            session: 's1',
            revision: 2,
            sequence: 2,
            status: AndroidPlaybackStatus.buffering,
          ),
        );
        native.loadReply.complete(
          AndroidLoadReply(
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
        status: AndroidPlaybackStatus.buffering,
      ),
    );
    native.loadReply.complete(
      AndroidLoadReply(
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

AndroidStateMessage _state({
  String? session,
  int revision = 0,
  int sequence = 0,
  AndroidPlaybackStatus status = AndroidPlaybackStatus.idle,
}) => AndroidStateMessage(
  loadRequestId: session == null ? null : 'load-1',
  sessionId: session,
  revision: revision,
  sequence: sequence,
  status: status,
  timeline: AndroidTimelineMessage(
    positionMs: 0,
    bufferedPositionMs: 0,
    isSeekable: false,
    isLive: false,
  ),
  audioTracks: [],
  videoTracks: [],
  engine: AndroidEngine.media3,
  decoderMode: AndroidDecoderMode.unknown,
  metrics: AndroidMetricsMessage(),
);

Future<YlPlayerController> _controller(_Native native) async {
  final backend = await AndroidPlayer.create(
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

final class _Factory implements AndroidFactoryTransport {
  @override
  Future<AndroidCreateReply> create(AndroidCreateRequest request) async =>
      AndroidCreateReply(
        schemaMajor: 2,
        spiMajor: 2,
        channelSuffix: 'controller-test',
        textureId: 1,
        implementationName: 'android-test',
        implementationVersion: 'test',
        capabilities: AndroidCapabilitiesMessage(
          deviceProfile: 'android',
          availableEngines: [AndroidEngine.media3],
          decoderEvidence: AndroidDecoderEvidence.none,
          hardwareVideoCodecs: [],
          supportedOperations: [],
        ),
        initialState: _state(),
      );
}

/// Only native create/attach/assess/load/stop/dispose are needed by these consumers.
/// Unexpected commands fail instead of supplying placeholder success.
final class _Native implements AndroidPlayerTransport {
  AndroidPlayerFlutterApi? callbacks;
  AndroidLoadRequest? request;
  final _replies = <Completer<AndroidLoadReply>>[];
  Completer<AndroidLoadReply> get loadReply => _replies.first;
  @override
  Future<void> attach() async {}
  @override
  Future<AndroidAssessmentReply> assess(AndroidAssessRequest request) async =>
      AndroidAssessmentReply(
        outcome: AndroidAssessmentOutcome.compatible,
        satisfiedRequirements: [],
        limitations: [],
      );
  @override
  Future<AndroidLoadReply> load(AndroidLoadRequest request) {
    this.request = request;
    final reply = Completer<AndroidLoadReply>();
    _replies.add(reply);
    return reply.future;
  }

  @override
  Future<void> dispose() async {}
  @override
  Future<void> play(AndroidSessionCommand command) =>
      throw UnimplementedError();
  @override
  Future<void> pause(AndroidSessionCommand command) =>
      throw UnimplementedError();
  @override
  Future<void> seekTo(AndroidSeekCommand command) => throw UnimplementedError();
  @override
  Future<void> seekToLiveEdge(AndroidSessionCommand command) =>
      throw UnimplementedError();
  @override
  Future<void> setPlaybackSpeed(AndroidSpeedCommand command) =>
      throw UnimplementedError();
  @override
  Future<void> selectAudioTrack(AndroidTrackCommand command) =>
      throw UnimplementedError();
  @override
  Future<void> setVideoConstraints(AndroidVideoConstraintsCommand command) =>
      throw UnimplementedError();
  @override
  Future<void> setVolume(double volume) => throw UnimplementedError();
  @override
  Future<void> stop() async {}
}
