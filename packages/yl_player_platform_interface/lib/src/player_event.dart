import 'dart:collection';

import 'media_track.dart';
import 'player_error.dart';
import 'player_state.dart';

/// Base type for discrete player events.
sealed class YlPlayerEvent {
  const YlPlayerEvent();
}

final class YlFirstFrameEvent extends YlPlayerEvent {
  const YlFirstFrameEvent({this.width, this.height});

  final int? width;
  final int? height;
}

final class YlRetryEvent extends YlPlayerEvent {
  const YlRetryEvent({
    required this.attempt,
    required this.delay,
    required this.error,
  });

  final int attempt;
  final Duration delay;
  final YlPlayerError error;
}

final class YlFallbackEvent extends YlPlayerEvent {
  const YlFallbackEvent({
    required this.from,
    required this.to,
    required this.reason,
  });

  final YlPlaybackEngine from;
  final YlPlaybackEngine to;
  final YlPlayerError reason;
}

final class YlTracksChangedEvent extends YlPlayerEvent {
  YlTracksChangedEvent({
    List<YlMediaTrack> audioTracks = const <YlMediaTrack>[],
    List<YlMediaTrack> videoTracks = const <YlMediaTrack>[],
  }) : audioTracks = UnmodifiableListView<YlMediaTrack>(
         List<YlMediaTrack>.of(audioTracks),
       ),
       videoTracks = UnmodifiableListView<YlMediaTrack>(
         List<YlMediaTrack>.of(videoTracks),
       );

  final List<YlMediaTrack> audioTracks;
  final List<YlMediaTrack> videoTracks;
}

final class YlErrorEvent extends YlPlayerEvent {
  const YlErrorEvent(this.error);

  final YlPlayerError error;
}
