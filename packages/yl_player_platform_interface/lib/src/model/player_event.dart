import 'capabilities.dart';
import 'failure.dart';
import 'identifiers.dart';
import 'value_helpers.dart';

/// A discrete session event, timed from an implementation-local monotonic epoch.
sealed class YlPlayerEvent {
  const YlPlayerEvent({
    required this.sessionId,
    required this.revision,
    required this.occurredAt,
  });
  final YlPlaybackSessionId sessionId;
  final int revision;
  final Duration occurredAt;
}

final class YlFirstFrameEvent extends YlPlayerEvent {
  const YlFirstFrameEvent({
    required super.sessionId,
    required super.revision,
    required super.occurredAt,
  });
  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        sessionId == other.sessionId &&
        revision == other.revision &&
        occurredAt == other.occurredAt,
  );
  @override
  int get hashCode =>
      Object.hashAll([YlFirstFrameEvent, sessionId, revision, occurredAt]);
  @override
  String toString() =>
      'YlFirstFrameEvent(sessionId: $sessionId, revision: $revision, occurredAt: $occurredAt)';
}

final class YlRetryScheduledEvent extends YlPlayerEvent {
  const YlRetryScheduledEvent({
    required super.sessionId,
    required super.revision,
    required super.occurredAt,
    required this.retryIndex,
    required this.delay,
    required this.failure,
  });
  final int retryIndex;
  final Duration delay;
  final YlFailure failure;
  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        sessionId == other.sessionId &&
        revision == other.revision &&
        occurredAt == other.occurredAt &&
        retryIndex == other.retryIndex &&
        delay == other.delay &&
        failure == other.failure,
  );
  @override
  int get hashCode => Object.hashAll([
    YlRetryScheduledEvent,
    sessionId,
    revision,
    occurredAt,
    retryIndex,
    delay,
    failure,
  ]);
  @override
  String toString() =>
      'YlRetryScheduledEvent(sessionId: $sessionId, revision: $revision, occurredAt: $occurredAt, retryIndex: $retryIndex, delay: $delay, failure: $failure)';
}

final class YlPlaybackEngineChangedEvent extends YlPlayerEvent {
  const YlPlaybackEngineChangedEvent({
    required super.sessionId,
    required super.revision,
    required super.occurredAt,
    required this.previousEngine,
    required this.engine,
  });
  final YlPlaybackEngine previousEngine;
  final YlPlaybackEngine engine;
  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        sessionId == other.sessionId &&
        revision == other.revision &&
        occurredAt == other.occurredAt &&
        previousEngine == other.previousEngine &&
        engine == other.engine,
  );
  @override
  int get hashCode => Object.hashAll([
    YlPlaybackEngineChangedEvent,
    sessionId,
    revision,
    occurredAt,
    previousEngine,
    engine,
  ]);
  @override
  String toString() =>
      'YlPlaybackEngineChangedEvent(sessionId: $sessionId, revision: $revision, occurredAt: $occurredAt, previousEngine: $previousEngine, engine: $engine)';
}

final class YlPlaybackFailedEvent extends YlPlayerEvent {
  const YlPlaybackFailedEvent({
    required super.sessionId,
    required super.revision,
    required super.occurredAt,
    required this.failure,
  });
  final YlFailure failure;
  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        sessionId == other.sessionId &&
        revision == other.revision &&
        occurredAt == other.occurredAt &&
        failure == other.failure,
  );
  @override
  int get hashCode => Object.hashAll([
    YlPlaybackFailedEvent,
    sessionId,
    revision,
    occurredAt,
    failure,
  ]);
  @override
  String toString() =>
      'YlPlaybackFailedEvent(sessionId: $sessionId, revision: $revision, occurredAt: $occurredAt, failure: $failure)';
}
