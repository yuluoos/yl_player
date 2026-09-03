import 'dart:collection';

import 'capabilities.dart';
import 'media_track.dart';
import 'playback_metrics.dart';
import 'player_error.dart';

const Object _notProvided = Object();

/// Semantic playback states shared by all native engines.
enum YlPlaybackStatus {
  idle,
  opening,
  ready,
  playing,
  paused,
  buffering,
  completed,
  error,
  disposed,
}

/// Identifies the native engine currently handling a source.
enum YlPlaybackEngine { unknown, media3, avPlayer, nativeFallback }

/// Pixel dimensions reported by the active video track.
final class YlVideoSize {
  const YlVideoSize(this.width, this.height)
    : assert(width > 0),
      assert(height > 0);

  final int width;
  final int height;
}

/// A seekable live-window range relative to the media timeline.
final class YlDvrWindow {
  YlDvrWindow({required this.start, required this.end})
    : assert(!end.isNegative),
      assert(end >= start);

  final Duration start;
  final Duration end;
}

/// The immutable public snapshot of one player instance.
final class YlPlayerState {
  YlPlayerState({
    this.status = YlPlaybackStatus.idle,
    this.position = Duration.zero,
    this.duration,
    this.bufferedPosition = Duration.zero,
    this.isLive = false,
    this.isSeekable = false,
    this.isAtLiveEdge = false,
    this.liveOffset,
    this.dvrWindow,
    this.videoSize,
    this.engine = YlPlaybackEngine.unknown,
    this.isHardwareDecoding = false,
    this.decoderName,
    List<YlMediaTrack> audioTracks = const <YlMediaTrack>[],
    List<YlMediaTrack> videoTracks = const <YlMediaTrack>[],
    this.capabilities,
    this.metrics = const YlPlaybackMetrics(),
    this.error,
  }) : audioTracks = UnmodifiableListView<YlMediaTrack>(
         List<YlMediaTrack>.of(audioTracks),
       ),
       videoTracks = UnmodifiableListView<YlMediaTrack>(
         List<YlMediaTrack>.of(videoTracks),
       );

  final YlPlaybackStatus status;
  final Duration position;
  final Duration? duration;
  final Duration bufferedPosition;
  final bool isLive;
  final bool isSeekable;
  final bool isAtLiveEdge;
  final Duration? liveOffset;
  final YlDvrWindow? dvrWindow;
  final YlVideoSize? videoSize;
  final YlPlaybackEngine engine;
  final bool isHardwareDecoding;
  final String? decoderName;
  final List<YlMediaTrack> audioTracks;
  final List<YlMediaTrack> videoTracks;
  final YlPlayerCapabilities? capabilities;
  final YlPlaybackMetrics metrics;
  final YlPlayerError? error;

  YlPlayerState copyWith({
    YlPlaybackStatus? status,
    Duration? position,
    Object? duration = _notProvided,
    Duration? bufferedPosition,
    bool? isLive,
    bool? isSeekable,
    bool? isAtLiveEdge,
    Object? liveOffset = _notProvided,
    Object? dvrWindow = _notProvided,
    Object? videoSize = _notProvided,
    YlPlaybackEngine? engine,
    bool? isHardwareDecoding,
    Object? decoderName = _notProvided,
    List<YlMediaTrack>? audioTracks,
    List<YlMediaTrack>? videoTracks,
    Object? capabilities = _notProvided,
    YlPlaybackMetrics? metrics,
    Object? error = _notProvided,
  }) => YlPlayerState(
    status: status ?? this.status,
    position: position ?? this.position,
    duration: identical(duration, _notProvided)
        ? this.duration
        : duration as Duration?,
    bufferedPosition: bufferedPosition ?? this.bufferedPosition,
    isLive: isLive ?? this.isLive,
    isSeekable: isSeekable ?? this.isSeekable,
    isAtLiveEdge: isAtLiveEdge ?? this.isAtLiveEdge,
    liveOffset: identical(liveOffset, _notProvided)
        ? this.liveOffset
        : liveOffset as Duration?,
    dvrWindow: identical(dvrWindow, _notProvided)
        ? this.dvrWindow
        : dvrWindow as YlDvrWindow?,
    videoSize: identical(videoSize, _notProvided)
        ? this.videoSize
        : videoSize as YlVideoSize?,
    engine: engine ?? this.engine,
    isHardwareDecoding: isHardwareDecoding ?? this.isHardwareDecoding,
    decoderName: identical(decoderName, _notProvided)
        ? this.decoderName
        : decoderName as String?,
    audioTracks: audioTracks ?? this.audioTracks,
    videoTracks: videoTracks ?? this.videoTracks,
    capabilities: identical(capabilities, _notProvided)
        ? this.capabilities
        : capabilities as YlPlayerCapabilities?,
    metrics: metrics ?? this.metrics,
    error: identical(error, _notProvided)
        ? this.error
        : error as YlPlayerError?,
  );
}
