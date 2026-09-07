import 'value_helpers.dart';

const _absent = Object();

/// Immutable Timeline value; validate at publication boundaries.
final class YlTimeline {
  const YlTimeline({
    this.position = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.duration,
    this.liveOffset,
    this.isSeekable = false,
    this.isLive = false,
    this.isAtLiveEdge,
    this.dvrWindow,
  });

  final Duration position;

  final Duration bufferedPosition;

  final Duration? duration;

  final Duration? liveOffset;

  final bool isSeekable;

  final bool isLive;

  final bool? isAtLiveEdge;

  final YlDvrWindow? dvrWindow;

  /// Omitted fields are preserved; explicit null clears nullable fields.
  YlTimeline copyWith({
    Duration? position,
    Duration? bufferedPosition,
    Object? duration = _absent,
    Object? liveOffset = _absent,
    bool? isSeekable,
    bool? isLive,
    Object? isAtLiveEdge = _absent,
    Object? dvrWindow = _absent,
  }) => YlTimeline(
    position: position ?? this.position,
    bufferedPosition: bufferedPosition ?? this.bufferedPosition,
    duration: identical(duration, _absent)
        ? this.duration
        : ylNullableValue<Duration>(duration),
    liveOffset: identical(liveOffset, _absent)
        ? this.liveOffset
        : ylNullableValue<Duration>(liveOffset),
    isSeekable: isSeekable ?? this.isSeekable,
    isLive: isLive ?? this.isLive,
    isAtLiveEdge: identical(isAtLiveEdge, _absent)
        ? this.isAtLiveEdge
        : ylNullableValue<bool>(isAtLiveEdge),
    dvrWindow: identical(dvrWindow, _absent)
        ? this.dvrWindow
        : ylNullableValue<YlDvrWindow>(dvrWindow),
  );

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        position == other.position &&
        bufferedPosition == other.bufferedPosition &&
        duration == other.duration &&
        liveOffset == other.liveOffset &&
        isSeekable == other.isSeekable &&
        isLive == other.isLive &&
        isAtLiveEdge == other.isAtLiveEdge &&
        dvrWindow == other.dvrWindow,
  );

  @override
  int get hashCode => Object.hashAll([
    position,
    bufferedPosition,
    duration,
    liveOffset,
    isSeekable,
    isLive,
    isAtLiveEdge,
    dvrWindow,
  ]);

  @override
  String toString() =>
      'YlTimeline(position: $position, bufferedPosition: $bufferedPosition, duration: $duration, liveOffset: $liveOffset, isSeekable: $isSeekable, isLive: $isLive, isAtLiveEdge: $isAtLiveEdge, dvrWindow: $dvrWindow)';
}

/// Immutable DvrWindow value; validate at publication boundaries.
final class YlDvrWindow {
  const YlDvrWindow({required this.start, required this.end});

  final Duration start;

  final Duration end;

  /// Omitted fields are preserved; explicit null clears nullable fields.
  YlDvrWindow copyWith({Duration? start, Duration? end}) =>
      YlDvrWindow(start: start ?? this.start, end: end ?? this.end);

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) => start == other.start && end == other.end,
  );

  @override
  int get hashCode => Object.hashAll([start, end]);

  @override
  String toString() => 'YlDvrWindow(start: $start, end: $end)';
}
