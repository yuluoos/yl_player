import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

final class FakePlayerPlatform extends YlPlayerPlatform {
  FakePlayerPlatform(this.player);
  final FakePlatformPlayer player;
  FakePlatformPlayer get backend => player;
  int createCount = 0;
  Object? createError;
  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerOptions options) async {
    createCount++;
    if (createError case final error?) throw error;
    return player;
  }
}

final class FakePlatformPlayer implements YlPlatformPlayer {
  @override
  YlPlatformImplementationInfo implementation =
      const YlPlatformImplementationInfo(
        name: 'fake',
        version: '2',
        spiMajor: 2,
      );
  @override
  final capabilities = YlPlayerCapabilities(deviceProfile: 'fake');
  final textureIdNotifier = ValueNotifier<int?>(42);
  final stateController = StreamController<YlPlayerState>.broadcast(sync: true);
  final eventController = StreamController<YlPlayerEvent>.broadcast(sync: true);
  YlPlayerState currentState = YlPlayerState();
  final loads = <Completer<YlPlatformLoadResult>>[];
  final calls = <String>[];
  final delayedCommands = <(String, YlPlaybackSessionId), Completer<void>>{};
  (String, YlPlaybackSessionId)? lastCommand;
  Object? commandError;
  Object? disposeError;
  bool emitIdleOnStop = true;
  Object? stopError;
  Completer<void>? stopReply;
  int disposeCount = 0;
  @override
  ValueListenable<int?> get textureId => textureIdNotifier;
  @override
  YlPlayerState get state => currentState;
  @override
  Stream<YlPlayerState> get states => stateController.stream;
  @override
  Stream<YlPlayerEvent> get events => eventController.stream;
  void emitState(YlPlayerState next) {
    currentState = next;
    stateController.add(next);
  }

  void emit({
    YlPlaybackSessionId? sessionId,
    YlPlaybackStatus status = YlPlaybackStatus.loading,
    YlFailure? failure,
  }) => emitState(
    YlPlayerState(
      revision: state.revision + 1,
      sessionId: sessionId ?? state.sessionId,
      status: status,
      failure: failure,
    ),
  );
  void emitEvent(YlPlayerEvent event) => eventController.add(event);
  void emitFirstFrame(YlPlaybackSessionId id, {int? revision}) => emitEvent(
    YlFirstFrameEvent(
      sessionId: id,
      revision: revision ?? state.revision,
      occurredAt: Duration.zero,
    ),
  );
  void commit(YlPlaybackSessionId id, {int? index, bool reply = true}) {
    emit(sessionId: id);
    if (reply) {
      loads[index ?? loads.length - 1].complete(
        YlPlatformLoadResult(sessionId: id),
      );
    }
  }

  void setTextureId(int? value) => textureIdNotifier.value = value;
  @override
  Future<YlSourceAssessment> assess(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) async =>
      YlSourceAssessment(outcome: YlSourceAssessmentOutcome.requiresInspection);
  @override
  Future<YlPlatformLoadResult> load(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) {
    final c = Completer<YlPlatformLoadResult>();
    loads.add(c);
    return c.future;
  }

  Future<void> command(String name, YlPlaybackSessionId id) async {
    calls.add(name);
    lastCommand = (name, id);
    if (commandError case final error?) throw error;
    await delayedCommands[(name, id)]?.future;
  }

  void delayCommand(String name, YlPlaybackSessionId id) {
    delayedCommands[(name, id)] = Completer<void>();
  }

  void completeCommand(String name, YlPlaybackSessionId id) {
    delayedCommands.remove((name, id))?.complete();
  }

  @override
  Future<void> play(YlPlaybackSessionId id) => command('play', id);
  @override
  Future<void> pause(YlPlaybackSessionId id) => command('pause', id);
  @override
  Future<void> seekTo(YlPlaybackSessionId id, Duration position) =>
      command('seekTo', id);
  @override
  Future<void> seekToLiveEdge(YlPlaybackSessionId id) =>
      command('seekToLiveEdge', id);
  @override
  Future<void> setPlaybackSpeed(YlPlaybackSessionId id, double speed) =>
      command('setPlaybackSpeed', id);
  @override
  Future<void> selectAudioTrack(YlPlaybackSessionId id, String trackId) =>
      command('selectAudioTrack', id);
  @override
  Future<void> setVideoConstraints(
    YlPlaybackSessionId id,
    YlVideoConstraints constraints,
  ) => command('setVideoConstraints', id);
  @override
  Future<void> setVolume(double volume) async {
    calls.add('setVolume');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (stopError case final error?) throw error;
    await stopReply?.future;
    if (emitIdleOnStop) emitState(YlPlayerState(revision: state.revision + 1));
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    if (disposeError case final error?) throw error;
    await stateController.close();
    await eventController.close();
  }
}
