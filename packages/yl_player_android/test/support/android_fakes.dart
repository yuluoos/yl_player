import 'dart:async';
import 'package:yl_player_android/src/android_player.dart';
import 'package:yl_player_android/src/android_transport.dart';
import 'package:yl_player_android/src/pigeon/yl_player_android.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

AndroidStateMessage wireState({
  String? requestId,
  String? session,
  int revision = 0,
  int sequence = 0,
  AndroidPlaybackStatus? status,
}) => AndroidStateMessage(
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
          ? AndroidPlaybackStatus.idle
          : AndroidPlaybackStatus.loading),
  timeline: AndroidTimelineMessage(
    positionMs: 0,
    bufferedPositionMs: 0,
    isSeekable: false,
    isLive: false,
  ),
  audioTracks: [],
  videoTracks: [],
  engine: AndroidEngine.media3,
  decoderMode: AndroidDecoderMode.unknown,
  metrics: AndroidMetricsMessage(),
);
AndroidFailureMessage wireFailure({
  AndroidFailureScope scope = AndroidFailureScope.session,
}) => AndroidFailureMessage(
  category: AndroidFailureCategory.network,
  code: 'network.failed',
  message: 'https://media.test/a?token=secret',
  retryable: true,
  scope: scope,
  diagnosticId: 'android-network-1',
);
AndroidCreateReply wireCreate({String suffix = 'instance-1'}) =>
    AndroidCreateReply(
      schemaMajor: 2,
      spiMajor: 2,
      channelSuffix: suffix,
      textureId: 42,
      implementationName: 'yl_player_android',
      implementationVersion: '0.2.0-dev.1',
      capabilities: AndroidCapabilitiesMessage(
        deviceProfile: 'android',
        availableEngines: [AndroidEngine.media3],
        decoderEvidence: AndroidDecoderEvidence.none,
        hardwareVideoCodecs: [],
        supportedOperations: AndroidPlayerOperation.values,
      ),
      initialState: wireState(),
    );
AndroidStateDeltaMessage wireDelta({
  String session = 's1',
  int previous = 4,
  int revision = 5,
  int sequence = 11,
}) => AndroidStateDeltaMessage(
  sessionId: session,
  previousRevision: previous,
  revision: revision,
  sequence: sequence,
  positionMs: 50,
  hasIsAtLiveEdge: false,
  hasLiveOffsetMs: false,
);
AndroidFirstFrameMessage wireFrame({
  String session = 's1',
  int revision = 5,
  int sequence = 12,
}) => AndroidFirstFrameMessage(
  sessionId: session,
  revision: revision,
  sequence: sequence,
  occurredAtMs: 90,
);
final source = YlNetworkSource(Uri.parse('https://media.test/a?token=secret'));

final class FakeFactory implements AndroidFactoryTransport {
  FakeFactory(this.reply);
  final AndroidCreateReply reply;
  AndroidCreateRequest? request;
  @override
  Future<AndroidCreateReply> create(AndroidCreateRequest request) async {
    this.request = request;
    return reply;
  }
}

final class FakeTransport implements AndroidPlayerTransport {
  AndroidPlayerFlutterApi? callbacks;
  final calls = <String>[];
  final loads = <Completer<AndroidLoadReply>>[];
  final requests = <AndroidLoadRequest>[];
  Future<AndroidAssessmentReply> Function()? assessment;
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
  Future<AndroidAssessmentReply> assess(AndroidAssessRequest request) async {
    calls.add('assess');
    return await assessment?.call() ??
        AndroidAssessmentReply(
          outcome: AndroidAssessmentOutcome.compatible,
          candidateEngine: AndroidEngine.media3,
          satisfiedRequirements: [],
          limitations: [],
        );
  }

  @override
  Future<AndroidLoadReply> load(AndroidLoadRequest request) {
    calls.add('load');
    requests.add(request);
    final c = Completer<AndroidLoadReply>();
    loads.add(c);
    return c.future;
  }

  @override
  Future<void> play(AndroidSessionCommand c) async {
    calls.add('play:${c.sessionId}');
    await playing?.call();
  }

  @override
  Future<void> pause(AndroidSessionCommand c) async {
    calls.add('pause:${c.sessionId}');
  }

  @override
  Future<void> seekTo(AndroidSeekCommand c) async {
    calls.add('seek:${c.sessionId}:${c.positionMs}');
  }

  @override
  Future<void> seekToLiveEdge(AndroidSessionCommand c) async {
    calls.add('live:${c.sessionId}');
  }

  @override
  Future<void> setPlaybackSpeed(AndroidSpeedCommand c) async {
    calls.add('speed:${c.sessionId}:${c.speed}');
  }

  @override
  Future<void> selectAudioTrack(AndroidTrackCommand c) async {
    calls.add('track:${c.sessionId}:${c.trackId}');
  }

  @override
  Future<void> setVideoConstraints(AndroidVideoConstraintsCommand c) async {
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

Future<AndroidPlayer> createFake(
  FakeTransport transport, {
  AndroidCreateReply? reply,
  void Function(AndroidPlayerFlutterApi?)? setup,
}) => AndroidPlayer.create(
  const YlPlayerOptions(),
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
  AndroidPlayer player, {
  String session = 's1',
  int revision = 4,
  int sequence = 10,
}) async {
  final loading = player.load(source);
  await flush();
  transport.loads.last.complete(
    AndroidLoadReply(
      loadRequestId: transport.requests.last.loadRequestId,
      sessionId: session,
    ),
  );
  transport.callbacks!.onState(
    wireState(session: session, revision: revision, sequence: sequence),
  );
  return loading;
}
