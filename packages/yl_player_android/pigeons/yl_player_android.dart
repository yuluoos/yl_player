// ignore_for_file: not_initialized_non_nullable_instance_field

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartPackageName: 'yl_player_android',
    dartOut: 'lib/src/pigeon/yl_player_android.g.dart',
    kotlinOut:
        'android/src/main/kotlin/dev/ylplayer/yl_player_android/pigeon/YlPlayerAndroid.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'dev.ylplayer.yl_player_android.pigeon',
    ),
  ),
)
enum AndroidSourceKind { file, network, content }

enum AndroidStreamIntent { automatic, onDemand, live }

enum AndroidMediaFormat {
  automatic,
  hls,
  mp4,
  mov,
  matroska,
  webm,
  mpegTs,
  mpegPs,
  flv,
  avi,
}

enum AndroidNetworkPolicyKind { platformDefault, managed }

enum AndroidBufferKind { automatic, lowLatency, smoothPlayback, bounded }

enum AndroidDecoderPolicy { systemDefault, hardwarePreferred, hardwareRequired }

enum AndroidAudioPolicy { appManaged, pluginManagedMediaPlayback }

enum AndroidAssessmentOutcome { compatible, incompatible, requiresInspection }

enum AndroidPlaybackStatus {
  idle,
  loading,
  ready,
  playing,
  paused,
  buffering,
  completed,
  failed,
}

enum AndroidEngine { unknown, media3 }

enum AndroidTrackKind { audio, video }

enum AndroidPlayerOperation {
  seek,
  seekToLiveEdge,
  playbackSpeed,
  audioTrackSelection,
  videoConstraints,
  volume,
  stop,
}

enum AndroidDecoderMode { unknown, hardware, software }

enum AndroidDecoderEvidence { none, hardwareOnly, hardwareAndSoftware }

enum AndroidFailureCategory {
  cancelled,
  unsupported,
  source,
  network,
  container,
  decoder,
  render,
  resource,
  protocol,
  platform,
  internal,
}

enum AndroidFailureScope { command, session, player }

class AndroidPlayerOptionsMessage {
  AndroidDecoderPolicy decoderPolicy;
  AndroidAudioPolicy audioPolicy;
  int positionUpdateIntervalMs;
}

class AndroidCreateRequest {
  int schemaMajor;
  AndroidPlayerOptionsMessage options;
}

class AndroidCreateReply {
  int schemaMajor;
  int spiMajor;
  String channelSuffix;
  int textureId;
  String implementationName;
  String implementationVersion;
  AndroidCapabilitiesMessage capabilities;
  AndroidStateMessage initialState;
}

class AndroidCapabilitiesMessage {
  String deviceProfile;
  List<AndroidEngine> availableEngines;
  AndroidDecoderEvidence decoderEvidence;
  int? maxConcurrentVideoDecoders;
  int? maxWidth;
  int? maxHeight;
  List<String> hardwareVideoCodecs;
  List<AndroidPlayerOperation> supportedOperations;
}

class AndroidHttpRequestMessage {
  Map<String, String> headers;
  Map<String, String> credentials;
}

class AndroidNetworkPolicyMessage {
  AndroidNetworkPolicyKind kind;
  int? connectTimeoutMs;
  int? readTimeoutMs;
  int? maxRetries;
  int? baseRetryDelayMs;
  int? maxRetryDelayMs;
  int? maxRedirects;
}

class AndroidSourceMessage {
  AndroidSourceKind kind;
  String locator;
  AndroidStreamIntent intent;
  AndroidMediaFormat format;
  AndroidHttpRequestMessage? request;
  AndroidNetworkPolicyMessage? networkPolicy;
}

class AndroidVideoConstraintsMessage {
  int? maxWidth;
  int? maxHeight;
  int? maxBitrate;
}

class AndroidBufferStrategyMessage {
  AndroidBufferKind kind;
  int? minDurationMs;
  int? maxDurationMs;
  int? maxManagedBytes;
}

class AndroidLoadOptionsMessage {
  bool autoplay;
  int? startPositionMs;
  AndroidBufferStrategyMessage bufferStrategy;
  AndroidVideoConstraintsMessage videoConstraints;
  AndroidDecoderPolicy? decoderPolicyOverride;
}

class AndroidAssessRequest {
  AndroidSourceMessage source;
  AndroidLoadOptionsMessage options;
}

class AndroidLoadRequest {
  AndroidSourceMessage source;
  AndroidLoadOptionsMessage options;
}

class AndroidAssessmentReply {
  AndroidAssessmentOutcome outcome;
  AndroidEngine? candidateEngine;
  List<String> satisfiedRequirements;
  List<String> limitations;
  AndroidFailureMessage? rejection;
}

class AndroidLoadReply {
  String sessionId;
}

class AndroidSessionCommand {
  String sessionId;
}

class AndroidSeekCommand {
  String sessionId;
  int positionMs;
}

class AndroidSpeedCommand {
  String sessionId;
  double speed;
}

class AndroidTrackCommand {
  String sessionId;
  String trackId;
}

class AndroidVideoConstraintsCommand {
  String sessionId;
  AndroidVideoConstraintsMessage constraints;
}

class AndroidDvrWindowMessage {
  int startMs;
  int endMs;
}

class AndroidTimelineMessage {
  int positionMs;
  int? durationMs;
  int bufferedPositionMs;
  bool isSeekable;
  bool isLive;
  bool? isAtLiveEdge;
  int? liveOffsetMs;
  AndroidDvrWindowMessage? dvrWindow;
}

class AndroidSizeMessage {
  double width;
  double height;
}

class AndroidVideoGeometryMessage {
  AndroidSizeMessage encodedSize;
  AndroidSizeMessage displaySize;
  double pixelAspectRatio;
  int rotationDegrees;
}

class AndroidTrackMessage {
  String id;
  AndroidTrackKind kind;
  String? label;
  String? language;
  String? codec;
  int? bitrate;
  int? width;
  int? height;
  bool isSelected;
}

class AndroidMetricsMessage {
  int? loadToReadyMs;
  int? loadToFirstFrameMs;
  int? rebufferCount;
  int? rebufferDurationMs;
  int? droppedVideoFrames;
  int? audioUnderruns;
  int? estimatedBitrate;
  int? managedBufferedDurationMs;
  int? managedBufferedBytes;
  int? liveOffsetMs;
  int? reconnectCount;
}

class AndroidFailureMessage {
  AndroidFailureCategory category;
  String code;
  String message;
  bool retryable;
  AndroidFailureScope scope;
  String diagnosticId;
}

class AndroidStateMessage {
  String? sessionId;
  int revision;
  int sequence;
  AndroidPlaybackStatus status;
  AndroidTimelineMessage timeline;
  AndroidVideoGeometryMessage? geometry;
  List<AndroidTrackMessage> audioTracks;
  List<AndroidTrackMessage> videoTracks;
  AndroidEngine engine;
  AndroidDecoderMode decoderMode;
  String? decoderIdentity;
  AndroidMetricsMessage metrics;
  AndroidFailureMessage? failure;
}

class AndroidStateDeltaMessage {
  String sessionId;
  int previousRevision;
  int revision;
  int sequence;
  int? positionMs;
  int? bufferedPositionMs;
  bool hasIsAtLiveEdge;
  bool? isAtLiveEdge;
  bool hasLiveOffsetMs;
  int? liveOffsetMs;
  AndroidMetricsDeltaMessage? metrics;
}

class AndroidMetricsDeltaMessage {
  bool hasLoadToReadyMs;
  int? loadToReadyMs;
  bool hasLoadToFirstFrameMs;
  int? loadToFirstFrameMs;
  bool hasRebufferCount;
  int? rebufferCount;
  bool hasRebufferDurationMs;
  int? rebufferDurationMs;
  bool hasDroppedVideoFrames;
  int? droppedVideoFrames;
  bool hasAudioUnderruns;
  int? audioUnderruns;
  bool hasEstimatedBitrate;
  int? estimatedBitrate;
  bool hasManagedBufferedDurationMs;
  int? managedBufferedDurationMs;
  bool hasManagedBufferedBytes;
  int? managedBufferedBytes;
  bool hasLiveOffsetMs;
  int? liveOffsetMs;
  bool hasReconnectCount;
  int? reconnectCount;
}

class AndroidFirstFrameMessage {
  String sessionId;
  int revision;
  int sequence;
  int occurredAtMs;
}

class AndroidRetryScheduledMessage {
  String sessionId;
  int revision;
  int sequence;
  int occurredAtMs;
  int retryIndex;
  int delayMs;
  AndroidFailureMessage failure;
}

class AndroidEngineChangedMessage {
  String sessionId;
  int revision;
  int sequence;
  int occurredAtMs;
  AndroidEngine previousEngine;
  AndroidEngine engine;
}

class AndroidPlaybackFailedMessage {
  String sessionId;
  int revision;
  int sequence;
  int occurredAtMs;
  AndroidFailureMessage failure;
}

@HostApi()
abstract class AndroidPlayerFactoryHostApi {
  AndroidCreateReply create(AndroidCreateRequest request);
}

@HostApi()
abstract class AndroidPlayerHostApi {
  void attach();
  AndroidAssessmentReply assess(AndroidAssessRequest request);
  @async
  AndroidLoadReply load(AndroidLoadRequest request);
  @async
  void play(AndroidSessionCommand command);
  void pause(AndroidSessionCommand command);
  void seekTo(AndroidSeekCommand command);
  void seekToLiveEdge(AndroidSessionCommand command);
  void setPlaybackSpeed(AndroidSpeedCommand command);
  void selectAudioTrack(AndroidTrackCommand command);
  void setVideoConstraints(AndroidVideoConstraintsCommand command);
  void setVolume(double volume);
  @async
  void stop();
  @async
  void dispose();
}

@FlutterApi()
abstract class AndroidPlayerFlutterApi {
  void onState(AndroidStateMessage state);
  void onStateDelta(AndroidStateDeltaMessage delta);
  void onFirstFrame(AndroidFirstFrameMessage event);
  void onRetryScheduled(AndroidRetryScheduledMessage event);
  void onEngineChanged(AndroidEngineChangedMessage event);
  void onPlaybackFailed(AndroidPlaybackFailedMessage event);
}
