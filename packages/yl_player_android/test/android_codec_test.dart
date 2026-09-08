import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:yl_player_android/src/android_codec.dart';
import 'package:yl_player_android/src/pigeon/yl_player_android.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'support/android_fakes.dart';

void main() {
  test(
    'actual Android capability and assessment decoding accepts native MIME and policy identifiers',
    () {
      final capabilities = AndroidCodec.capabilities(
        AndroidCapabilitiesMessage(
          deviceProfile: 'android',
          availableEngines: [AndroidEngine.media3],
          decoderEvidence: AndroidDecoderEvidence.hardwareAndSoftware,
          hardwareVideoCodecs: ['video/avc', 'video/hevc'],
          supportedOperations: [],
        ),
      );
      expect(capabilities.hardwareVideoCodecs, ['video/avc', 'video/hevc']);
      final assessment = AndroidCodec.assessment(
        AndroidAssessmentReply(
          outcome: AndroidAssessmentOutcome.requiresInspection,
          candidateEngine: AndroidEngine.media3,
          satisfiedRequirements: ['network.managed', 'buffer.automatic'],
          limitations: ['codec.requiresInspection', 'decoder.modeUnknown'],
        ),
      );
      expect(assessment.satisfiedRequirements, [
        YlRequirementId.networkManaged,
        YlRequirementId.bufferAutomatic,
      ]);
      expect(assessment.limitations, [
        YlLimitationId.codecRequiresInspection,
        YlLimitationId.decoderModeUnknown,
      ]);
    },
  );

  test('all complete enum counterparts retain exact set parity', () {
    final counterparts = <(List<Enum>, List<Enum>)>[
      (AndroidDecoderPolicy.values, YlDecoderPolicy.values),
      (AndroidAudioPolicy.values, YlAudioPolicy.values),
      (AndroidStreamIntent.values, YlStreamIntent.values),
      (AndroidMediaFormat.values, YlMediaFormat.values),
      (AndroidNetworkPolicyKind.values, YlNetworkPolicyKind.values),
      (AndroidBufferKind.values, YlBufferStrategyKind.values),
      (AndroidPlaybackStatus.values, YlPlaybackStatus.values),
      (AndroidTrackKind.values, YlTrackKind.values),
      (AndroidPlayerOperation.values, YlPlayerOperation.values),
      (AndroidDecoderMode.values, YlDecoderMode.values),
      (AndroidDecoderEvidence.values, YlDecoderEvidence.values),
      (AndroidFailureCategory.values, YlFailureCategory.values),
      (AndroidFailureScope.values, YlFailureScope.values),
      (AndroidAssessmentOutcome.values, YlSourceAssessmentOutcome.values),
    ];
    for (final (android, public) in counterparts) {
      expect(
        android.map((value) => value.name).toSet(),
        public.map((value) => value.name).toSet(),
        reason:
            '${android.first.runtimeType} must match its entire public counterpart',
      );
    }
  });
  test(
    'Android engines are the explicit public subset and source kinds cover all variants',
    () {
      const supported = {YlPlaybackEngine.unknown, YlPlaybackEngine.media3};
      expect(AndroidEngine.values.map(AndroidCodec.engine).toSet(), supported);
      expect(
        AndroidEngine.values.map((value) => value.name).toSet(),
        supported.map((value) => value.name).toSet(),
      );
      expect(YlPlaybackEngine.values.toSet(), containsAll(supported));
      final variants = <(YlMediaSource, AndroidSourceKind)>[
        (const YlFileSource('/a.mp4'), AndroidSourceKind.file),
        (
          YlNetworkSource(Uri.parse('https://media.test/a')),
          AndroidSourceKind.network,
        ),
        (
          YlAndroidContentSource(Uri.parse('content://media/a')),
          AndroidSourceKind.content,
        ),
      ];
      expect(
        variants.map((pair) => pair.$2).toSet(),
        AndroidSourceKind.values.toSet(),
      );
      for (final (source, kind) in variants) {
        expect(AndroidCodec.source(source).kind, kind);
      }
    },
  );

  test('metrics deltas distinguish every absent, set and cleared field', () {
    final state = AndroidCodec.state(wireState(session: 's1', revision: 4));
    final changes = AndroidMetricsDeltaMessage(
      hasLoadToReadyMs: true,
      loadToReadyMs: 12,
      hasLoadToFirstFrameMs: true,
      loadToFirstFrameMs: 12,
      hasRebufferCount: true,
      rebufferCount: 12,
      hasRebufferDurationMs: true,
      rebufferDurationMs: 12,
      hasDroppedVideoFrames: true,
      droppedVideoFrames: 12,
      hasAudioUnderruns: true,
      audioUnderruns: 12,
      hasEstimatedBitrate: true,
      estimatedBitrate: 12,
      hasManagedBufferedDurationMs: true,
      managedBufferedDurationMs: 12,
      hasManagedBufferedBytes: true,
      managedBufferedBytes: 12,
      hasLiveOffsetMs: true,
      liveOffsetMs: 12,
      hasReconnectCount: true,
      reconnectCount: 12,
    );
    final set = AndroidCodec.delta(state, wireDelta()..metrics = changes);
    expect(
      set.metrics,
      const YlPlaybackMetrics(
        loadToReady: Duration(milliseconds: 12),
        loadToFirstFrame: Duration(milliseconds: 12),
        rebufferCount: 12,
        rebufferDuration: Duration(milliseconds: 12),
        droppedVideoFrames: 12,
        audioUnderruns: 12,
        estimatedBitrate: 12,
        managedBufferedDuration: Duration(milliseconds: 12),
        managedBufferedBytes: 12,
        liveOffset: Duration(milliseconds: 12),
        reconnectCount: 12,
      ),
    );
    final absent = AndroidMetricsDeltaMessage(
      hasLoadToReadyMs: false,
      hasLoadToFirstFrameMs: false,
      hasRebufferCount: false,
      hasRebufferDurationMs: false,
      hasDroppedVideoFrames: false,
      hasAudioUnderruns: false,
      hasEstimatedBitrate: false,
      hasManagedBufferedDurationMs: false,
      hasManagedBufferedBytes: false,
      hasLiveOffsetMs: false,
      hasReconnectCount: false,
    );
    expect(
      AndroidCodec.delta(
        set,
        wireDelta(previous: 5, revision: 6)..metrics = absent,
      ).metrics,
      set.metrics,
    );
    changes.loadToReadyMs = null;
    changes.loadToFirstFrameMs = null;
    changes.rebufferCount = null;
    changes.rebufferDurationMs = null;
    changes.droppedVideoFrames = null;
    changes.audioUnderruns = null;
    changes.estimatedBitrate = null;
    changes.managedBufferedDurationMs = null;
    changes.managedBufferedBytes = null;
    changes.liveOffsetMs = null;
    changes.reconnectCount = null;
    expect(
      AndroidCodec.delta(
        set,
        wireDelta(previous: 5, revision: 6)..metrics = changes,
      ).metrics,
      const YlPlaybackMetrics(),
    );
    changes.rebufferCount = -1;
    expect(
      () => AndroidCodec.delta(set, wireDelta()..metrics = changes),
      throwsArgumentError,
    );
  });
  test('source metadata and load choices retain values across encoding', () {
    final encoded = AndroidCodec.source(
      YlNetworkSource(
        Uri.parse('https://media.test/a'),
        request: YlHttpRequest(
          headers: {'accept': 'video/mp4'},
          credentials: {'authorization': 'Bearer secret'},
        ),
        networkPolicy: const YlNetworkPolicy.managed(
          connectTimeout: Duration(milliseconds: 100),
          readTimeout: Duration(milliseconds: 200),
          maxRetries: 4,
          baseRetryDelay: Duration(milliseconds: 300),
          maxRetryDelay: Duration(milliseconds: 400),
          maxRedirects: 6,
        ),
      ),
    );
    expect(encoded.request!.headers, {'accept': 'video/mp4'});
    expect(encoded.request!.credentials, {'authorization': 'Bearer secret'});
    expect(encoded.networkPolicy!.connectTimeoutMs, 100);
    expect(encoded.networkPolicy!.readTimeoutMs, 200);
    expect(encoded.networkPolicy!.maxRetries, 4);
    expect(encoded.networkPolicy!.baseRetryDelayMs, 300);
    expect(encoded.networkPolicy!.maxRetryDelayMs, 400);
    expect(encoded.networkPolicy!.maxRedirects, 6);
    final load = AndroidCodec.loadOptions(
      const YlLoadOptions(
        autoplay: true,
        startPosition: Duration(milliseconds: 123),
        bufferStrategy: YlBufferStrategy.bounded(
          minDuration: Duration(milliseconds: 10),
          maxDuration: Duration(milliseconds: 20),
          maxManagedBytes: 30,
        ),
        videoConstraints: YlVideoConstraints(
          maxWidth: 40,
          maxHeight: 50,
          maxBitrate: 60,
        ),
      ),
    );
    expect(load.autoplay, isTrue);
    expect(load.startPositionMs, 123);
    expect(load.bufferStrategy.minDurationMs, 10);
    expect(load.bufferStrategy.maxDurationMs, 20);
    expect(load.bufferStrategy.maxManagedBytes, 30);
    expect(load.videoConstraints.maxWidth, 40);
    expect(load.videoConstraints.maxHeight, 50);
    expect(load.videoConstraints.maxBitrate, 60);
  });
  test(
    'timeline preserves nullable live metadata and rejects inverted DVR ranges',
    () {
      final message = wireState()
        ..timeline = AndroidTimelineMessage(
          positionMs: 10,
          durationMs: 100,
          bufferedPositionMs: 90,
          isSeekable: true,
          isLive: true,
          isAtLiveEdge: false,
          liveOffsetMs: -4,
          dvrWindow: AndroidDvrWindowMessage(startMs: 2, endMs: 100),
        );
      final timeline = AndroidCodec.state(message).timeline;
      expect(
        timeline,
        const YlTimeline(
          position: Duration(milliseconds: 10),
          duration: Duration(milliseconds: 100),
          bufferedPosition: Duration(milliseconds: 90),
          isSeekable: true,
          isLive: true,
          isAtLiveEdge: false,
          liveOffset: Duration.zero,
          dvrWindow: YlDvrWindow(
            start: Duration(milliseconds: 2),
            end: Duration(milliseconds: 100),
          ),
        ),
      );
      message.timeline.dvrWindow!.endMs = 1;
      expect(() => AndroidCodec.state(message), throwsArgumentError);
    },
  );
  test(
    'outbound enums preserve every policy, format, intent and source kind',
    () {
      for (final policy in YlDecoderPolicy.values) {
        final encoded = AndroidCodec.playerOptions(
          YlPlayerOptions(decoderPolicy: policy),
        );
        expect(encoded.decoderPolicy.name, policy.name);
        expect(
          AndroidCodec.loadOptions(
            YlLoadOptions(decoderPolicyOverride: policy),
          ).decoderPolicyOverride!.name,
          policy.name,
        );
      }
      for (final policy in YlAudioPolicy.values) {
        expect(
          AndroidCodec.playerOptions(
            YlPlayerOptions(audioPolicy: policy),
          ).audioPolicy.name,
          policy.name,
        );
      }
      for (final format in YlMediaFormat.values) {
        for (final intent in YlStreamIntent.values) {
          final encoded = AndroidCodec.source(
            YlNetworkSource(
              Uri.parse('https://media.test/a'),
              intent: intent,
              format: format,
            ),
          );
          expect(encoded.format.name, format.name);
          expect(encoded.intent.name, intent.name);
          expect(encoded.kind, AndroidSourceKind.network);
        }
      }
      expect(
        AndroidCodec.source(const YlFileSource('/a.mp4')).kind,
        AndroidSourceKind.file,
      );
      expect(
        AndroidCodec.source(
          YlAndroidContentSource(Uri.parse('content://media/a')),
        ).kind,
        AndroidSourceKind.content,
      );
      for (final policy in [
        const YlNetworkPolicy.platformDefault(),
        const YlNetworkPolicy.managed(),
      ]) {
        final encoded = AndroidCodec.source(
          YlNetworkSource(
            Uri.parse('https://media.test/a'),
            networkPolicy: policy,
          ),
        ).networkPolicy!;
        expect(encoded.kind.name, policy.kind.name);
        expect(encoded.connectTimeoutMs, policy.connectTimeout?.inMilliseconds);
        expect(encoded.maxRetries, policy.maxRetries);
      }
      for (final strategy in [
        const YlBufferStrategy.automatic(),
        const YlBufferStrategy.lowLatency(),
        const YlBufferStrategy.smoothPlayback(),
        const YlBufferStrategy.bounded(
          minDuration: Duration.zero,
          maxDuration: Duration(seconds: 1),
          maxManagedBytes: 1024,
        ),
      ]) {
        expect(
          AndroidCodec.loadOptions(
            YlLoadOptions(bufferStrategy: strategy),
          ).bufferStrategy.kind.name,
          strategy.kind.name,
        );
      }
    },
  );
  test(
    'inbound enums cover statuses, engines, decoder evidence/mode, tracks, operations and failures',
    () {
      for (final status in AndroidPlaybackStatus.values) {
        expect(
          AndroidCodec.state(
            wireState(
              session: status == AndroidPlaybackStatus.idle ? null : 's1',
              status: status,
            ),
          ).status.name,
          status.name,
        );
      }
      for (final engine in AndroidEngine.values) {
        expect(AndroidCodec.engine(engine).name, engine.name);
      }
      for (final mode in AndroidDecoderMode.values) {
        final wire = wireState()..decoderMode = mode;
        expect(AndroidCodec.state(wire).decoderMode.name, mode.name);
      }
      for (final evidence in AndroidDecoderEvidence.values) {
        final wire = wireCreate().capabilities..decoderEvidence = evidence;
        final decoded = AndroidCodec.capabilities(wire);
        expect(decoded.decoderEvidence.name, evidence.name);
        expect(
          decoded.supportedOperations.map((v) => v.name),
          YlPlayerOperation.values.map((v) => v.name),
        );
      }
      for (final kind in AndroidTrackKind.values) {
        expect(
          AndroidCodec.track(
            AndroidTrackMessage(id: 't1', kind: kind, isSelected: true),
          ).kind.name,
          kind.name,
        );
      }
      for (final category in AndroidFailureCategory.values) {
        for (final scope in AndroidFailureScope.values) {
          final wire = wireFailure(scope: scope)..category = category;
          final failure = AndroidCodec.failure(wire);
          expect(failure.category.name, category.name);
          expect(failure.scope.name, scope.name);
        }
      }
    },
  );
  test(
    'assessment maps outcomes and rejects inconsistent rejection or unsafe identifiers',
    () {
      for (final outcome in AndroidAssessmentOutcome.values) {
        final wire = AndroidAssessmentReply(
          outcome: outcome,
          candidateEngine: AndroidEngine.media3,
          satisfiedRequirements: ['network.managed'],
          limitations: ['decoder.modeUnknown'],
          rejection: outcome == AndroidAssessmentOutcome.incompatible
              ? wireFailure()
              : null,
        );
        final decoded = AndroidCodec.assessment(wire);
        expect(decoded.outcome.name, outcome.name);
        expect(
          decoded.satisfiedRequirements.single,
          YlRequirementId.networkManaged,
        );
        expect(decoded.limitations.single, YlLimitationId.decoderModeUnknown);
        wire.rejection = outcome == AndroidAssessmentOutcome.incompatible
            ? null
            : wireFailure();
        expect(() => AndroidCodec.assessment(wire), throwsArgumentError);
      }
      expect(
        () => AndroidCodec.assessment(
          AndroidAssessmentReply(
            outcome: AndroidAssessmentOutcome.compatible,
            satisfiedRequirements: ['https://media.test/a'],
            limitations: [],
          ),
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'failure prose is fixed and transport errors never expose native details',
    () {
      final failure = AndroidCodec.failure(wireFailure());
      expect(failure.message, 'Playback operation failed.');
      expect(failure.diagnosticId, 'android-network-1');
      final unsafe = wireFailure()
        ..code = 'https://media.test/a'
        ..diagnosticId = 'token=secret';
      final sanitized = AndroidCodec.failure(unsafe);
      expect('$sanitized ${sanitized.message}', isNot(contains('secret')));
      expect(sanitized.code, YlFailureCodes.platformFailure);
      final typed = AndroidCodec.exception(
        PlatformException(
          code: 'native',
          message: 'secret',
          details: wireFailure(),
        ),
      );
      expect(typed.failure.code, YlFailureCodes.networkFailed);
      final disconnected = AndroidCodec.exception(
        PlatformException(code: 'channel-error', message: 'secret'),
      );
      expect(disconnected.failure.scope, YlFailureScope.player);
      expect(disconnected.failure.message, isNot(contains('secret')));
    },
  );
  test(
    'nullable metrics, clamp only live offset and preserve display geometry',
    () {
      expect(
        AndroidCodec.metrics(AndroidMetricsMessage()),
        const YlPlaybackMetrics(),
      );
      final metrics = AndroidCodec.metrics(
        AndroidMetricsMessage(
          loadToReadyMs: 1,
          loadToFirstFrameMs: 2,
          rebufferCount: 3,
          rebufferDurationMs: 4,
          droppedVideoFrames: 5,
          audioUnderruns: 6,
          estimatedBitrate: 7,
          managedBufferedDurationMs: 8,
          managedBufferedBytes: 9,
          liveOffsetMs: -1,
          reconnectCount: 10,
        ),
      );
      expect(
        metrics,
        const YlPlaybackMetrics(
          loadToReady: Duration(milliseconds: 1),
          loadToFirstFrame: Duration(milliseconds: 2),
          rebufferCount: 3,
          rebufferDuration: Duration(milliseconds: 4),
          droppedVideoFrames: 5,
          audioUnderruns: 6,
          estimatedBitrate: 7,
          managedBufferedDuration: Duration(milliseconds: 8),
          managedBufferedBytes: 9,
          liveOffset: Duration.zero,
          reconnectCount: 10,
        ),
      );
      final wire = wireState()
        ..geometry = AndroidVideoGeometryMessage(
          encodedSize: AndroidSizeMessage(width: 1920, height: 1088),
          displaySize: AndroidSizeMessage(width: 1920, height: 1080),
          pixelAspectRatio: 1.5,
          rotationDegrees: 90,
        );
      final geometry = AndroidCodec.state(wire).videoGeometry!;
      expect(geometry.encodedSize.height, 1088);
      expect(geometry.displaySize.height, 1080);
      expect(geometry.displayAspectRatio, .375);
      wire.geometry!.rotationDegrees = 45;
      expect(() => AndroidCodec.state(wire), throwsArgumentError);
    },
  );
  test(
    'validate raw millisecond bounds before Duration overflow and nullable deltas',
    () {
      const maxMs = 9223372036854775;
      expect(AndroidCodec.milliseconds(maxMs).inMilliseconds, maxMs);
      for (final invalid in [-1, maxMs + 1, 0x7fffffffffffffff]) {
        expect(() => AndroidCodec.milliseconds(invalid), throwsArgumentError);
      }
      expect(
        () => AndroidCodec.state(wireState(revision: -1)),
        throwsArgumentError,
      );
      expect(
        () => AndroidCodec.state(wireState(sequence: -1)),
        throwsArgumentError,
      );
      expect(
        () => AndroidCodec.state(wireState(session: '')),
        throwsArgumentError,
      );
      expect(
        () => AndroidCodec.metrics(AndroidMetricsMessage(rebufferCount: -1)),
        throwsArgumentError,
      );
      expect(
        () => AndroidCodec.playerOptions(
          const YlPlayerOptions(
            positionUpdateInterval: Duration(milliseconds: 0x80000000),
          ),
        ),
        throwsArgumentError,
      );
      final state = AndroidCodec.state(wireState(session: 's1', revision: 4));
      final changed = AndroidCodec.delta(
        state,
        wireDelta()
          ..hasLiveOffsetMs = true
          ..liveOffsetMs = -9,
      );
      expect(changed.timeline.liveOffset, Duration.zero);
      final cleared = AndroidCodec.delta(
        changed,
        wireDelta()..hasLiveOffsetMs = true,
      );
      expect(cleared.timeline.liveOffset, isNull);
    },
  );
}
