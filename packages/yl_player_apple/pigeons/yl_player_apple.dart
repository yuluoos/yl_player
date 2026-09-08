// ignore_for_file: not_initialized_non_nullable_instance_field

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartPackageName: 'yl_player_apple',
    dartOut: 'lib/src/pigeon/yl_player_apple.g.dart',
    swiftOut:
        'darwin/yl_player_apple/Sources/yl_player_apple/Generated/YlPlayerApple.g.swift',
  ),
)
enum ApplePlatform { ios, macos }

enum AppleSourceKind { file, network, content }

enum AppleStreamIntent { automatic, onDemand, live }

enum AppleMediaFormat {
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

enum AppleNetworkPolicyKind { platformDefault, managed }

enum AppleBufferKind { automatic, lowLatency, smoothPlayback, bounded }

enum AppleDecoderPolicy { systemDefault, hardwarePreferred, hardwareRequired }

enum AppleAudioPolicy { appManaged, pluginManagedMediaPlayback }

enum AppleAssessmentOutcome { compatible, incompatible, requiresInspection }

enum ApplePlaybackStatus {
  idle,
  loading,
  ready,
  playing,
  paused,
  buffering,
  completed,
  failed,
}

enum AppleEngine { unknown, avPlayer, managedFallback }

enum AppleTrackKind { audio, video }

enum ApplePlayerOperation {
  seek,
  seekToLiveEdge,
  playbackSpeed,
  audioTrackSelection,
  videoConstraints,
  volume,
  stop,
}

enum AppleDecoderMode { unknown, hardware, software }

enum AppleDecoderEvidence { none, hardwareOnly, hardwareAndSoftware }

enum AppleFailureCategory {
  cancelled,
  unsupported,
  source,
  network,
  container,
  decoder,
  render,
  resource,

  /// Maps to public YlFailureCategory.protocol at the Dart/native boundaries.
  protocolFailure,
  platform,

  /// Maps to public YlFailureCategory.internal at the Dart/native boundaries.
  internalFailure,
}

enum AppleFailureScope { command, session, player }

class ApplePlayerOptionsMessage {
  AppleDecoderPolicy decoderPolicy;
  AppleAudioPolicy audioPolicy;
  int positionUpdateIntervalMs;
}

class AppleCreateRequest {
  int schemaMajor;
  ApplePlayerOptionsMessage options;
}

class AppleCreateReply {
  int schemaMajor;
  int spiMajor;
  String channelSuffix;
  int textureId;
  ApplePlatform platform;
  String implementationName;
  String implementationVersion;
  AppleCapabilitiesMessage capabilities;
  AppleStateMessage initialState;
}

class AppleCapabilitiesMessage {
  String deviceProfile;
  List<AppleEngine> availableEngines;
  AppleDecoderEvidence decoderEvidence;
  int? maxConcurrentVideoDecoders;
  int? maxWidth;
  int? maxHeight;
  List<String> hardwareVideoCodecs;
  List<ApplePlayerOperation> supportedOperations;
}

class AppleHttpRequestMessage {
  Map<String, String> headers;
  Map<String, String> credentials;
}

class AppleNetworkPolicyMessage {
  AppleNetworkPolicyKind kind;
  int? connectTimeoutMs;
  int? readTimeoutMs;
  int? maxRetries;
  int? baseRetryDelayMs;
  int? maxRetryDelayMs;
  int? maxRedirects;
}

class AppleSourceMessage {
  AppleSourceKind kind;
  String locator;
  AppleStreamIntent intent;
  AppleMediaFormat format;
  AppleHttpRequestMessage? request;
  AppleNetworkPolicyMessage? networkPolicy;
}

class AppleVideoConstraintsMessage {
  int? maxWidth;
  int? maxHeight;
  int? maxBitrate;
}

class AppleBufferStrategyMessage {
  AppleBufferKind kind;
  int? minDurationMs;
  int? maxDurationMs;
  int? maxManagedBytes;
}

class AppleLoadOptionsMessage {
  bool autoplay;
  int? startPositionMs;
  AppleBufferStrategyMessage bufferStrategy;
  AppleVideoConstraintsMessage videoConstraints;
  AppleDecoderPolicy? decoderPolicyOverride;
}

class AppleAssessRequest {
  AppleSourceMessage source;
  AppleLoadOptionsMessage options;
}

class AppleLoadRequest {
  String loadRequestId;
  AppleSourceMessage source;
  AppleLoadOptionsMessage options;
}

class AppleAssessmentReply {
  AppleAssessmentOutcome outcome;
  AppleEngine? candidateEngine;
  List<String> satisfiedRequirements;
  List<String> limitations;
  AppleFailureMessage? rejection;
}

class AppleLoadReply {
  String loadRequestId;
  String sessionId;
}

class AppleSessionCommand {
  String sessionId;
}

class AppleSeekCommand {
  String sessionId;
  int positionMs;
}

class AppleSpeedCommand {
  String sessionId;
  double speed;
}

class AppleTrackCommand {
  String sessionId;
  String trackId;
}

class AppleVideoConstraintsCommand {
  String sessionId;
  AppleVideoConstraintsMessage constraints;
}

class AppleDvrWindowMessage {
  int startMs;
  int endMs;
}

class AppleTimelineMessage {
  int positionMs;
  int? durationMs;
  int bufferedPositionMs;
  bool isSeekable;
  bool isLive;
  bool? isAtLiveEdge;
  int? liveOffsetMs;
  AppleDvrWindowMessage? dvrWindow;
}

class AppleSizeMessage {
  double width;
  double height;
}

class AppleVideoGeometryMessage {
  AppleSizeMessage encodedSize;
  AppleSizeMessage displaySize;
  double pixelAspectRatio;
  int rotationDegrees;
}

class AppleTrackMessage {
  String id;
  AppleTrackKind kind;
  String? label;
  String? language;
  String? codec;
  int? bitrate;
  int? width;
  int? height;
  bool isSelected;
}

class AppleMetricsMessage {
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

class AppleFailureMessage {
  AppleFailureCategory category;
  String code;
  String message;
  bool retryable;
  AppleFailureScope scope;
  String diagnosticId;
}

class AppleStateMessage {
  String? loadRequestId;
  String? sessionId;
  int revision;
  int sequence;
  ApplePlaybackStatus status;
  AppleTimelineMessage timeline;
  AppleVideoGeometryMessage? geometry;
  List<AppleTrackMessage> audioTracks;
  List<AppleTrackMessage> videoTracks;
  AppleEngine engine;
  AppleDecoderMode decoderMode;
  String? decoderIdentity;
  AppleMetricsMessage metrics;
  AppleFailureMessage? failure;
}

class AppleStateDeltaMessage {
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
  AppleMetricsDeltaMessage? metrics;
}

class AppleMetricsDeltaMessage {
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

class AppleFirstFrameMessage {
  String sessionId;
  int revision;
  int sequence;
  int occurredAtMs;
}

class AppleRetryScheduledMessage {
  String sessionId;
  int revision;
  int sequence;
  int occurredAtMs;
  int retryIndex;
  int delayMs;
  AppleFailureMessage failure;
}

class AppleEngineChangedMessage {
  String sessionId;
  int revision;
  int sequence;
  int occurredAtMs;
  AppleEngine previousEngine;
  AppleEngine engine;
}

class ApplePlaybackFailedMessage {
  String sessionId;
  int revision;
  int sequence;
  int occurredAtMs;
  AppleFailureMessage failure;
}

@HostApi()
abstract class ApplePlayerFactoryHostApi {
  AppleCreateReply create(AppleCreateRequest request);
}

@HostApi()
abstract class ApplePlayerHostApi {
  void attach();
  AppleAssessmentReply assess(AppleAssessRequest request);
  @async
  AppleLoadReply load(AppleLoadRequest request);
  @async
  void play(AppleSessionCommand command);
  void pause(AppleSessionCommand command);
  void seekTo(AppleSeekCommand command);
  @async
  void seekToLiveEdge(AppleSessionCommand command);
  void setPlaybackSpeed(AppleSpeedCommand command);
  @async
  void selectAudioTrack(AppleTrackCommand command);
  void setVideoConstraints(AppleVideoConstraintsCommand command);
  void setVolume(double volume);
  @async
  void stop();
  @async
  void dispose();
}

@FlutterApi()
abstract class ApplePlayerFlutterApi {
  void onState(AppleStateMessage state);
  void onStateDelta(AppleStateDeltaMessage delta);
  void onFirstFrame(AppleFirstFrameMessage event);
  void onRetryScheduled(AppleRetryScheduledMessage event);
  void onEngineChanged(AppleEngineChangedMessage event);
  void onPlaybackFailed(ApplePlaybackFailedMessage event);
}
