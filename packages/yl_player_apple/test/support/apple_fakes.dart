import 'dart:async';
import 'package:yl_player_apple/src/apple_player.dart';
import 'package:yl_player_apple/src/apple_transport.dart';
import 'package:yl_player_apple/src/pigeon/yl_player_apple.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

AppleStateMessage wireState({
  String? requestId,
  String? session,
  int revision = 0,
  int sequence = 0,
  ApplePlaybackStatus? status,
}) => AppleStateMessage(
  loadRequestId: session == null
      ? null
      : requestId ??
            'load-${session.length > 1 ? session.substring(1) : 'unknown'}',
  sessionId: session,
  revision: revision,
  sequence: sequence,
  status:
      status ??
      (session == null
          ? ApplePlaybackStatus.idle
          : ApplePlaybackStatus.loading),
  timeline: AppleTimelineMessage(
    positionMs: 0,
    bufferedPositionMs: 0,
    isSeekable: false,
    isLive: false,
  ),
  audioTracks: [],
  videoTracks: [],
  engine: AppleEngine.avPlayer,
  decoderMode: AppleDecoderMode.unknown,
  metrics: AppleMetricsMessage(),
);
AppleFailureMessage wireFailure({
  AppleFailureScope scope = AppleFailureScope.session,
}) => AppleFailureMessage(
  category: AppleFailureCategory.network,
  code: 'network.failed',
  message: 'https://media.test/a?token=secret',
  retryable: true,
  scope: scope,
  diagnosticId: 'apple-network-1',
);
AppleCreateReply wireCreate({String suffix = 'instance-1'}) => AppleCreateReply(
  schemaMajor: 2,
  spiMajor: 2,
  platform: ApplePlatform.ios,
  channelSuffix: suffix,
  textureId: 42,
  implementationName: 'yl_player_apple',
  implementationVersion: '0.2.0-dev.1',
  capabilities: AppleCapabilitiesMessage(
    deviceProfile: 'apple',
    availableEngines: [AppleEngine.avPlayer],
    decoderEvidence: AppleDecoderEvidence.none,
    hardwareVideoCodecs: [],
    supportedOperations: ApplePlayerOperation.values,
  ),
  initialState: wireState(),
);
AppleStateDeltaMessage wireDelta({
  String session = 's1',
  int previous = 4,
  int revision = 5,
  int sequence = 11,
}) => AppleStateDeltaMessage(
  sessionId: session,
  previousRevision: previous,
  revision: revision,
  sequence: sequence,
  positionMs: 50,
  hasIsAtLiveEdge: false,
  hasLiveOffsetMs: false,
);
AppleFirstFrameMessage wireFrame({
  String session = 's1',
  int revision = 5,
  int sequence = 12,
}) => AppleFirstFrameMessage(
  sessionId: session,
  revision: revision,
  sequence: sequence,
  occurredAtMs: 90,
);
final source = YlNetworkSource(Uri.parse('https://media.test/a?token=secret'));

final class FakeFactory implements AppleFactoryTransport {
  FakeFactory(this.reply);
  final AppleCreateReply reply;
  AppleCreateRequest? request;
  @override
  Future<AppleCreateReply> create(AppleCreateRequest request) async {
    this.request = request;
    return reply;
  }
}

final class FakeTransport implements ApplePlayerTransport {
  ApplePlayerFlutterApi? callbacks;
  final calls = <String>[];
  final loads = <Completer<AppleLoadReply>>[];
  final requests = <AppleLoadRequest>[];
  Future<AppleAssessmentReply> Function()? assessment;
  Future<void> Function()? attaching;
  Future<void> Function()? stopping;
  Future<void> Function()? disposing;
  Future<void> Function()? playing;
  @override
  Future<void> attach() async {
    calls.add('attach');
    await attaching?.call();
  }

  @override
  Future<AppleAssessmentReply> assess(AppleAssessRequest request) async {
    calls.add('assess');
    return await assessment?.call() ??
        AppleAssessmentReply(
          outcome: AppleAssessmentOutcome.compatible,
          candidateEngine: AppleEngine.avPlayer,
          satisfiedRequirements: [],
          limitations: [],
        );
  }

  @override
  Future<AppleLoadReply> load(AppleLoadRequest request) {
    calls.add('load');
    requests.add(request);
    final c = Completer<AppleLoadReply>();
    loads.add(c);
    return c.future;
  }

  @override
  Future<void> play(AppleSessionCommand c) async {
    calls.add('play:${c.sessionId}');
    await playing?.call();
  }

  @override
  Future<void> pause(AppleSessionCommand c) async {
    calls.add('pause:${c.sessionId}');
  }

  @override
  Future<void> seekTo(AppleSeekCommand c) async {
    calls.add('seek:${c.sessionId}:${c.positionMs}');
  }

  @override
  Future<void> seekToLiveEdge(AppleSessionCommand c) async {
    calls.add('live:${c.sessionId}');
  }

  @override
  Future<void> setPlaybackSpeed(AppleSpeedCommand c) async {
    calls.add('speed:${c.sessionId}:${c.speed}');
  }

  @override
  Future<void> selectAudioTrack(AppleTrackCommand c) async {
    calls.add('track:${c.sessionId}:${c.trackId}');
  }

  @override
  Future<void> setVideoConstraints(AppleVideoConstraintsCommand c) async {
    calls.add('constraints:${c.sessionId}:${c.constraints.maxWidth}');
  }

  @override
  Future<void> setVolume(double volume) async {
    calls.add('volume:$volume');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    await stopping?.call();
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await disposing?.call();
  }
}

Future<ApplePlayer> createFake(
  FakeTransport transport, {
  AppleCreateReply? reply,
  YlPlayerOptions options = const YlPlayerOptions(),
  void Function(ApplePlayerFlutterApi?)? setup,
}) => ApplePlayer.create(
  options,
  factory: FakeFactory(reply ?? wireCreate()),
  transportForSuffix: (_) => transport,
  setupCallbacks: (_, api) {
    transport.callbacks = api;
    setup?.call(api);
  },
);
Future<void> flush() => Future<void>.delayed(Duration.zero);
Future<YlPlatformLoadResult> commit(
  FakeTransport transport,
  ApplePlayer player, {
  String session = 's1',
  int revision = 4,
  int sequence = 10,
}) async {
  final loading = player.load(source);
  await flush();
  transport.loads.last.complete(
    AppleLoadReply(
      loadRequestId: transport.requests.last.loadRequestId,
      sessionId: session,
    ),
  );
  transport.callbacks!.onState(
    wireState(session: session, revision: revision, sequence: sequence),
  );
  return loading;
}
