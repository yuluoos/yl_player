import 'package:flutter/foundation.dart';

import 'value_helpers.dart';

/// Playback goals, not measured latency or continuity guarantees.
enum YlLivePlaybackMode { smoothPlayback, lowLatency }

/// An authoritative committed live mode and this session's switchable modes.
/// An empty list permits reporting a known Load mode without runtime switching.
/// Null `YlPlayerState.livePlayback` means no mode evidence, never a default.
final class YlLivePlaybackState {
  YlLivePlaybackState({
    required this.mode,
    required List<YlLivePlaybackMode> switchableModes,
  }) : switchableModes = List.unmodifiable(switchableModes) {
    if (this.switchableModes.toSet().length != this.switchableModes.length) {
      throw ArgumentError('Duplicate switchable live modes.');
    }
  }

  final YlLivePlaybackMode mode;
  final List<YlLivePlaybackMode> switchableModes;

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        mode == other.mode &&
        listEquals(switchableModes, other.switchableModes),
  );

  @override
  int get hashCode => Object.hash(mode, Object.hashAll(switchableModes));

  @override
  String toString() =>
      'YlLivePlaybackState(mode: $mode, switchableModes: $switchableModes)';
}
