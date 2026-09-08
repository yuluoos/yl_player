import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'android_codec.dart';
import 'pigeon/yl_player_android.g.dart';

/// One reducer per channel suffix. Native owns cross-method acknowledgement FIFO;
/// these callbacks synchronously finish reduction before acknowledging delivery.
final class AndroidCallbacks implements AndroidPlayerFlutterApi {
  AndroidCallbacks({
    required YlPlayerState initialState,
    required int initialSequence,
    required this.onFullState,
    required this.onDelta,
    required this.onAcceptedState,
    required this.onEvent,
    required this.onInvalid,
  }) : state = initialState,
       _sequence = initialSequence;

  YlPlayerState state;
  int _sequence;
  int _invalidCount = 0;
  bool _readyObserved = false;
  bool closed = false;
  final _eventSequences = <int>{};
  final void Function(YlPlayerState state, int sequence, String? loadRequestId)
  onFullState;
  final void Function(AndroidStateDeltaMessage delta) onDelta;
  final void Function(YlPlayerState state) onAcceptedState;
  final void Function(YlPlayerEvent event, int sequence) onEvent;
  final void Function() onInvalid;

  void _decode(void Function() action) {
    if (closed) return;
    try {
      action();
    } on ArgumentError {
      if (++_invalidCount >= 3) onInvalid();
    }
  }

  bool isNewer(int revision, int sequence) =>
      revision > state.revision && sequence > _sequence;

  bool canAccept(YlPlayerState next, int sequence) =>
      isNewer(next.revision, sequence);

  static bool hasReadyEvidence(YlPlayerState next) =>
      next.metrics.loadToReady != null ||
      const [
        YlPlaybackStatus.ready,
        YlPlaybackStatus.playing,
        YlPlaybackStatus.paused,
        YlPlaybackStatus.completed,
      ].contains(next.status);

  bool acceptState(
    YlPlayerState next,
    int sequence, {
    bool readyObserved = false,
  }) {
    if (closed || !canAccept(next, sequence)) return false;
    if (next.sessionId != state.sessionId) {
      _readyObserved = false;
      _eventSequences.clear();
    }
    if (readyObserved || hasReadyEvidence(next)) {
      _readyObserved = true;
    }
    if (!_readyObserved && next.status == YlPlaybackStatus.buffering) {
      next = next.copyWith(status: YlPlaybackStatus.loading);
    }
    state = next;
    _sequence = sequence;
    _invalidCount = 0;
    onAcceptedState(next);
    return true;
  }

  bool acceptEvent(YlPlayerEvent event, int sequence) =>
      !closed &&
      event.sessionId == state.sessionId &&
      _eventSequences.add(sequence);

  @override
  void onState(AndroidStateMessage value) => _decode(() {
    onFullState(AndroidCodec.state(value), value.sequence, value.loadRequestId);
  });

  @override
  void onStateDelta(AndroidStateDeltaMessage value) => _decode(() {
    AndroidCodec.deltaIdentity(value);
    onDelta(value);
  });

  void _event(YlPlayerEvent event, int sequence) {
    AndroidCodec.integer(sequence);
    validateYlPlayerEvent(event);
    onEvent(event, sequence);
  }

  @override
  void onFirstFrame(AndroidFirstFrameMessage value) => _decode(() {
    _event(
      YlFirstFrameEvent(
        sessionId: AndroidCodec.session(value.sessionId),
        revision: value.revision,
        occurredAt: AndroidCodec.milliseconds(value.occurredAtMs),
      ),
      value.sequence,
    );
  });

  @override
  void onRetryScheduled(AndroidRetryScheduledMessage value) => _decode(() {
    _event(
      YlRetryScheduledEvent(
        sessionId: AndroidCodec.session(value.sessionId),
        revision: value.revision,
        occurredAt: AndroidCodec.milliseconds(value.occurredAtMs),
        retryIndex: value.retryIndex,
        delay: AndroidCodec.milliseconds(value.delayMs),
        failure: AndroidCodec.failure(value.failure),
      ),
      value.sequence,
    );
  });

  @override
  void onEngineChanged(AndroidEngineChangedMessage value) => _decode(() {
    _event(
      YlPlaybackEngineChangedEvent(
        sessionId: AndroidCodec.session(value.sessionId),
        revision: value.revision,
        occurredAt: AndroidCodec.milliseconds(value.occurredAtMs),
        previousEngine: AndroidCodec.engine(value.previousEngine),
        engine: AndroidCodec.engine(value.engine),
      ),
      value.sequence,
    );
  });

  @override
  void onPlaybackFailed(AndroidPlaybackFailedMessage value) => _decode(() {
    _event(
      YlPlaybackFailedEvent(
        sessionId: AndroidCodec.session(value.sessionId),
        revision: value.revision,
        occurredAt: AndroidCodec.milliseconds(value.occurredAtMs),
        failure: AndroidCodec.failure(value.failure),
      ),
      value.sequence,
    );
  });
}
