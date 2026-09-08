import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

const secret = 'https://private.example/movie?token=secret';
const failure = YlFailure(
  category: YlFailureCategory.decoder,
  code: 'decoder.unavailable',
  message: secret,
  retryable: true,
  scope: YlFailureScope.session,
  diagnosticId: 'diagnostic-1',
);

YlPlayerState snapshot() => YlPlayerState(
  revision: 7,
  sessionId: YlPlaybackSessionId('session-1'),
  status: YlPlaybackStatus.playing,
  timeline: YlTimeline(
    position: Duration(seconds: 3),
    duration: Duration(minutes: 1),
    bufferedPosition: Duration(seconds: 8),
    isSeekable: true,
    isLive: false,
  ),
  videoGeometry: YlVideoGeometry(
    encodedSize: YlPixelSize(1920, 1088),
    displaySize: YlPixelSize(1920, 1080),
    pixelAspectRatio: 1,
    rotationDegrees: 0,
  ),
  engine: YlPlaybackEngine.media3,
  decoderMode: YlDecoderMode.hardware,
  decoderIdentity: secret,
  metrics: YlPlaybackMetrics(rebufferCount: 0),
  failure: failure,
);

void main() {
  test(
    'independently allocated snapshots use structural equality and hash',
    () {
      final left = snapshot();
      final right = snapshot();
      expect(identical(left, right), isFalse);
      expect(left, right);
      expect(left.hashCode, right.hashCode);
      expect(left.copyWith(revision: 8), isNot(left));
      expect(left.copyWith(decoderMode: YlDecoderMode.software), isNot(left));
      expect(left.copyWith(timeline: const YlTimeline()), isNot(left));
      expect(left.videoGeometry!.displayAspectRatio, closeTo(16 / 9, 0.0001));
    },
  );

  test(
    'state copy clears every nullable field and preserves unrelated state',
    () {
      final original = snapshot();
      final cleared = original.copyWith(
        sessionId: null,
        videoGeometry: null,
        decoderIdentity: null,
        failure: null,
      );
      expect(cleared.sessionId, isNull);
      expect(cleared.videoGeometry, isNull);
      expect(cleared.decoderIdentity, isNull);
      expect(cleared.failure, isNull);
      expect(cleared.revision, 7);
      expect(cleared.timeline.position, const Duration(seconds: 3));
      expect(original.copyWith(), original);
    },
  );

  test(
    'tracks and state own immutable collections with structural equality',
    () {
      final track = YlMediaTrack(
        id: secret,
        kind: YlTrackKind.video,
        isSelected: true,
        label: secret,
        language: secret,
        codec: secret,
        bitrate: 1000,
        width: 1920,
        height: 1080,
      );
      final tracks = [track];
      final state = YlPlayerState(videoTracks: tracks);
      tracks.clear();
      expect(state.videoTracks, [track]);
      expect(() => state.videoTracks.clear(), throwsUnsupportedError);
      expect(state, YlPlayerState(videoTracks: [track.copyWith()]));
      expect(track.copyWith(isSelected: false), isNot(track));
      final cleared = track.copyWith(
        label: null,
        language: null,
        codec: null,
        bitrate: null,
        width: null,
        height: null,
      );
      expect([
        cleared.label,
        cleared.language,
        cleared.codec,
        cleared.bitrate,
        cleared.width,
        cleared.height,
      ], everyElement(isNull));
      expect(cleared.id, secret);
      for (final invalid in [0, -1]) {
        expect(
          () => validateYlMediaTrack(track.copyWith(bitrate: invalid)),
          throwsArgumentError,
        );
        expect(
          () => validateYlMediaTrack(track.copyWith(width: invalid)),
          throwsArgumentError,
        );
        expect(
          () => validateYlMediaTrack(track.copyWith(height: invalid)),
          throwsArgumentError,
        );
      }
      expect(
        () =>
            validateYlMediaTrack(YlMediaTrack(id: '', kind: YlTrackKind.audio)),
        throwsArgumentError,
      );
      expect(
        () => validateYlPlayerState(YlPlayerState(audioTracks: [track])),
        throwsArgumentError,
      );
      expect('$track $state', isNot(contains(secret)));
    },
  );

  test(
    'geometry applies PAR then unapplied rotation and rejects invalid const values',
    () {
      for (final rotation in [0, 90, 180, 270]) {
        final geometry = YlVideoGeometry(
          encodedSize: YlPixelSize(720, 576),
          displaySize: YlPixelSize(720, 576),
          pixelAspectRatio: 16 / 15,
          rotationDegrees: rotation,
        );
        validateYlVideoGeometry(geometry);
        expect(
          geometry.displayAspectRatio,
          closeTo(rotation == 90 || rotation == 270 ? 3 / 4 : 4 / 3, 0.00001),
        );
        expect(geometry, geometry.copyWith());
        expect(geometry.hashCode, geometry.copyWith().hashCode);
      }
      for (final size in [
        const YlPixelSize(0, 10),
        const YlPixelSize(10, -1),
        const YlPixelSize(double.infinity, 10),
        const YlPixelSize(10, double.nan),
      ]) {
        expect(() => validateYlPixelSize(size), throwsArgumentError);
      }
      const good = YlVideoGeometry(
        encodedSize: YlPixelSize(1, 1),
        displaySize: YlPixelSize(1, 1),
      );
      for (final par in [0.0, -1.0, double.nan, double.infinity]) {
        expect(
          () => validateYlVideoGeometry(good.copyWith(pixelAspectRatio: par)),
          throwsArgumentError,
        );
      }
      expect(
        () => validateYlVideoGeometry(good.copyWith(rotationDegrees: 45)),
        throwsArgumentError,
      );
      expect(
        () => validateYlPlayerState(
          YlPlayerState(
            videoGeometry: good.copyWith(
              displaySize: const YlPixelSize(1e308, 1),
              pixelAspectRatio: 2,
            ),
          ),
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'timeline validates nonnegative time and ordered DVR without requiring buffered >= position',
    () {
      const timeline = YlTimeline(
        position: Duration(seconds: 20),
        bufferedPosition: Duration(seconds: 10),
        duration: Duration(seconds: 60),
        liveOffset: Duration.zero,
        isLive: true,
        isAtLiveEdge: true,
        dvrWindow: YlDvrWindow(
          start: Duration(seconds: 5),
          end: Duration(seconds: 50),
        ),
      );
      validateYlTimeline(timeline);
      expect(timeline, timeline.copyWith());
      expect(timeline.hashCode, timeline.copyWith().hashCode);
      final cleared = timeline.copyWith(
        duration: null,
        liveOffset: null,
        isAtLiveEdge: null,
        dvrWindow: null,
      );
      expect([
        cleared.duration,
        cleared.liveOffset,
        cleared.isAtLiveEdge,
        cleared.dvrWindow,
      ], everyElement(isNull));
      expect(cleared.position, const Duration(seconds: 20));
      const negative = Duration(microseconds: -1);
      for (final invalid in [
        timeline.copyWith(position: negative),
        timeline.copyWith(bufferedPosition: negative),
        timeline.copyWith(duration: negative),
        timeline.copyWith(liveOffset: negative),
        timeline.copyWith(
          dvrWindow: const YlDvrWindow(
            start: Duration(seconds: 2),
            end: Duration(seconds: 1),
          ),
        ),
        timeline.copyWith(
          dvrWindow: const YlDvrWindow(start: negative, end: Duration.zero),
        ),
      ]) {
        expect(() => validateYlTimeline(invalid), throwsArgumentError);
      }
    },
  );

  test(
    'all common metrics preserve unknown versus measured zero and clear independently',
    () {
      const unknown = YlPlaybackMetrics();
      final zero = YlPlaybackMetrics(
        loadToReady: Duration.zero,
        loadToFirstFrame: Duration.zero,
        rebufferCount: 0,
        rebufferDuration: Duration.zero,
        droppedVideoFrames: 0,
        audioUnderruns: 0,
        estimatedBitrate: 0,
        managedBufferedDuration: Duration.zero,
        managedBufferedBytes: 0,
        liveOffset: Duration.zero,
        reconnectCount: 0,
      );
      expect(unknown, isNot(zero));
      expect(zero, zero.copyWith());
      expect(zero.hashCode, zero.copyWith().hashCode);
      validateYlPlaybackMetrics(zero);
      final cleared = zero.copyWith(
        loadToReady: null,
        loadToFirstFrame: null,
        rebufferCount: null,
        rebufferDuration: null,
        droppedVideoFrames: null,
        audioUnderruns: null,
        estimatedBitrate: null,
        managedBufferedDuration: null,
        managedBufferedBytes: null,
        liveOffset: null,
        reconnectCount: null,
      );
      expect(cleared, unknown);
      expect(zero.copyWith(rebufferCount: null).managedBufferedBytes, 0);
      const negative = Duration(microseconds: -1);
      for (final invalid in [
        zero.copyWith(loadToReady: negative),
        zero.copyWith(loadToFirstFrame: negative),
        zero.copyWith(rebufferCount: -1),
        zero.copyWith(rebufferDuration: negative),
        zero.copyWith(droppedVideoFrames: -1),
        zero.copyWith(audioUnderruns: -1),
        zero.copyWith(estimatedBitrate: -1),
        zero.copyWith(managedBufferedDuration: negative),
        zero.copyWith(managedBufferedBytes: -1),
        zero.copyWith(liveOffset: negative),
        zero.copyWith(reconnectCount: -1),
      ]) {
        expect(() => validateYlPlaybackMetrics(invalid), throwsArgumentError);
      }
    },
  );

  test(
    'capabilities copy collections, preserve unknown limits and validate safe metadata',
    () {
      final engines = [YlPlaybackEngine.media3];
      final operations = [YlPlayerOperation.seek];
      final codecs = ['h264'];
      final capabilities = YlPlayerCapabilities(
        deviceProfile: 'android.tv',
        availableEngines: engines,
        supportedOperations: operations,
        hardwareVideoCodecs: codecs,
        decoderEvidence: YlDecoderEvidence.hardwareOnly,
      );
      engines.clear();
      operations.clear();
      codecs.clear();
      expect(capabilities.availableEngines, [YlPlaybackEngine.media3]);
      expect(capabilities.supportedOperations, [YlPlayerOperation.seek]);
      expect(capabilities.hardwareVideoCodecs, ['h264']);
      for (final list in [
        capabilities.availableEngines,
        capabilities.supportedOperations,
        capabilities.hardwareVideoCodecs,
      ]) {
        expect(() => list.clear(), throwsUnsupportedError);
      }
      expect(capabilities, capabilities.copyWith());
      expect(capabilities.hashCode, capabilities.copyWith().hashCode);
      expect(capabilities.maxWidth, isNull);
      expect(
        capabilities.copyWith(maxWidth: 100).copyWith(maxWidth: null),
        capabilities,
      );
      expect(
        () => YlPlayerCapabilities(deviceProfile: secret),
        throwsArgumentError,
      );
      expect(
        () => YlPlayerCapabilities(
          deviceProfile: 'ios',
          hardwareVideoCodecs: [secret],
        ),
        throwsArgumentError,
      );
      expect(
        () => YlPlayerCapabilities(deviceProfile: 'ios', maxWidth: 0),
        throwsArgumentError,
      );
      expect(
        () => YlPlayerCapabilities(deviceProfile: 'ios', maxHeight: -1),
        throwsArgumentError,
      );
      expect(
        () => YlPlayerCapabilities(
          deviceProfile: 'ios',
          maxConcurrentVideoDecoders: 0,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'assessment IDs preserve exact core and extension wire values without diagnostics leakage',
    () {
      final requirements = {
        YlRequirementId.networkPlatformDefault: 'network.platformDefault',
        YlRequirementId.networkManaged: 'network.managed',
        YlRequirementId.bufferAutomatic: 'buffer.automatic',
        YlRequirementId.bufferLowLatency: 'buffer.lowLatency',
        YlRequirementId.bufferSmoothPlayback: 'buffer.smoothPlayback',
        YlRequirementId.bufferBounded: 'buffer.bounded',
        YlRequirementId.decoderSystemDefault: 'decoder.systemDefault',
        YlRequirementId.decoderHardwarePreferred: 'decoder.hardwarePreferred',
        YlRequirementId.decoderHardwareRequired: 'decoder.hardwareRequired',
      };
      final limitations = {
        YlLimitationId.sourceRequiresInspection: 'source.requiresInspection',
        YlLimitationId.codecRequiresInspection: 'codec.requiresInspection',
        YlLimitationId.decoderModeUnknown: 'decoder.modeUnknown',
        YlLimitationId.bufferOsMemoryExcluded: 'buffer.osMemoryExcluded',
        YlLimitationId.networkSystemStackOpaque: 'network.systemStackOpaque',
      };
      for (final entry in requirements.entries) {
        expect(YlRequirementId(entry.value), entry.key);
        expect(YlRequirementId(entry.value).hashCode, entry.key.hashCode);
        expect(entry.key.value, entry.value);
      }
      for (final entry in limitations.entries) {
        expect(YlLimitationId(entry.value), entry.key);
        expect(entry.key.value, entry.value);
      }
      const extension = 'vendor.customPolicy-v2';
      expect(YlRequirementId(extension).value, extension);
      expect(YlLimitationId(extension).value, extension);
      expect(
        '${YlRequirementId(extension)} ${YlLimitationId(extension)}',
        isNot(contains(extension)),
      );
      for (final invalid in [
        '',
        'single',
        'Vendor.policy',
        'vendor..policy',
        'vendor.policy\n',
        'vendor/policy',
        secret,
        'a.${'b' * 127}',
      ]) {
        for (final make in [YlRequirementId.new, YlLimitationId.new]) {
          try {
            make(invalid);
            fail('Accepted invalid identifier');
          } on ArgumentError catch (error) {
            expect(error.invalidValue, isNull);
            if (invalid.isNotEmpty) {
              expect(error.toString(), isNot(contains(invalid)));
            }
          }
        }
      }
    },
  );

  test(
    'assessments enforce rejection exactly for incompatible and copy lists',
    () {
      final requirements = [YlRequirementId.networkManaged];
      final limitations = [YlLimitationId.codecRequiresInspection];
      final assessment = YlSourceAssessment(
        outcome: YlSourceAssessmentOutcome.requiresInspection,
        satisfiedRequirements: requirements,
        limitations: limitations,
      );
      requirements.clear();
      limitations.clear();
      expect(assessment.candidateEngine, isNull);
      expect(assessment.satisfiedRequirements, [
        YlRequirementId.networkManaged,
      ]);
      expect(assessment.limitations, [YlLimitationId.codecRequiresInspection]);
      expect(() => assessment.limitations.clear(), throwsUnsupportedError);
      expect(
        () => assessment.satisfiedRequirements.clear(),
        throwsUnsupportedError,
      );
      expect(assessment, assessment.copyWith());
      expect(assessment.hashCode, assessment.copyWith().hashCode);
      final incompatible = assessment.copyWith(
        outcome: YlSourceAssessmentOutcome.incompatible,
        rejection: failure,
      );
      expect(
        incompatible.copyWith(
          outcome: YlSourceAssessmentOutcome.requiresInspection,
          rejection: null,
        ),
        assessment,
      );
      expect(
        assessment
            .copyWith(candidateEngine: YlPlaybackEngine.avPlayer)
            .copyWith(candidateEngine: null),
        assessment,
      );
      expect(
        () =>
            YlSourceAssessment(outcome: YlSourceAssessmentOutcome.incompatible),
        throwsArgumentError,
      );
      expect(
        () => assessment.copyWith(rejection: failure),
        throwsArgumentError,
      );
      expect('$incompatible', isNot(contains(secret)));
    },
  );

  test(
    'events correlate with a monotonic epoch and compare complete payloads',
    () {
      YlFirstFrameEvent first() => YlFirstFrameEvent(
        sessionId: YlPlaybackSessionId('s'),
        revision: 8,
        occurredAt: Duration(milliseconds: 1234),
      );
      final event = first();
      expect(event, first());
      expect(event.hashCode, first().hashCode);
      expect(event.occurredAt, const Duration(milliseconds: 1234));
      const retry = YlRetryScheduledEvent(
        sessionId: YlPlaybackSessionId('s'),
        revision: 8,
        occurredAt: Duration(milliseconds: 1234),
        retryIndex: 1,
        delay: Duration.zero,
        failure: failure,
      );
      const changed = YlPlaybackEngineChangedEvent(
        sessionId: YlPlaybackSessionId('s'),
        revision: 8,
        occurredAt: Duration(milliseconds: 1234),
        previousEngine: YlPlaybackEngine.avPlayer,
        engine: YlPlaybackEngine.managedFallback,
      );
      const failed = YlPlaybackFailedEvent(
        sessionId: YlPlaybackSessionId('s'),
        revision: 8,
        occurredAt: Duration(milliseconds: 1234),
        failure: failure,
      );
      for (final value in [event, retry, changed, failed]) {
        validateYlPlayerEvent(value);
        expect(value.sessionId.value, 's');
        expect(value.revision, 8);
        expect('$value', isNot(contains(secret)));
      }
      expect(event, isNot(retry));
      expect(retry, isNot(failed));
      expect(changed, isNot(failed));
    },
  );

  test(
    'publication boundaries reject invalid revisions, event timestamps and retries',
    () {
      expect(
        () => validateYlPlayerState(YlPlayerState(revision: -1)),
        throwsArgumentError,
      );
      expect(
        () => validateYlPlayerState(
          YlPlayerState(sessionId: const YlPlaybackSessionId('')),
        ),
        throwsArgumentError,
      );
      for (final event in [
        const YlFirstFrameEvent(
          sessionId: YlPlaybackSessionId('s'),
          revision: -1,
          occurredAt: Duration.zero,
        ),
        const YlFirstFrameEvent(
          sessionId: YlPlaybackSessionId('s'),
          revision: 0,
          occurredAt: Duration(microseconds: -1),
        ),
        const YlFirstFrameEvent(
          sessionId: YlPlaybackSessionId(''),
          revision: 0,
          occurredAt: Duration.zero,
        ),
        const YlRetryScheduledEvent(
          sessionId: YlPlaybackSessionId('s'),
          revision: 0,
          occurredAt: Duration.zero,
          retryIndex: 0,
          delay: Duration.zero,
          failure: failure,
        ),
        const YlRetryScheduledEvent(
          sessionId: YlPlaybackSessionId('s'),
          revision: 0,
          occurredAt: Duration.zero,
          retryIndex: 1,
          delay: Duration(microseconds: -1),
          failure: failure,
        ),
      ]) {
        expect(() => validateYlPlayerEvent(event), throwsArgumentError);
      }
      validateYlPlayerState(snapshot().copyWith(revision: 0x7fffffffffffffff));
      expect('${snapshot()}', isNot(contains(secret)));
    },
  );
  test('nullable copy input errors redact arbitrary runtime values', () {
    final state = snapshot();
    for (final copy in <void Function()>[
      () => state.copyWith(sessionId: secret),
      () => state.copyWith(videoGeometry: secret),
      () => state.copyWith(failure: secret),
      () => state.copyWith(decoderIdentity: [secret]),
      () => const YlTimeline().copyWith(duration: secret),
      () => const YlTimeline().copyWith(isAtLiveEdge: secret),
      () => const YlTimeline().copyWith(dvrWindow: secret),
      () => const YlPlaybackMetrics().copyWith(rebufferCount: secret),
      () => YlSourceAssessment(
        outcome: YlSourceAssessmentOutcome.compatible,
      ).copyWith(candidateEngine: secret),
      () =>
          YlPlayerCapabilities(deviceProfile: 'ios').copyWith(maxWidth: secret),
      () => const YlMediaTrack(
        id: 'a',
        kind: YlTrackKind.audio,
      ).copyWith(label: [secret]),
    ]) {
      try {
        copy();
        fail('Accepted a wrong copy value type');
      } on ArgumentError catch (error) {
        expect(error.invalidValue, isNull);
        expect('$error', isNot(contains(secret)));
      }
    }
  });

  test(
    'publication accepts player-scoped pre-load failure and rejects session mismatch',
    () {
      const playerFailure = YlFailure(
        category: YlFailureCategory.platform,
        code: 'platform.failure',
        message: secret,
        retryable: false,
        scope: YlFailureScope.player,
        diagnosticId: 'diagnostic-2',
      );
      validateYlPlayerState(YlPlayerState());
      validateYlPlayerState(
        YlPlayerState(status: YlPlaybackStatus.failed, failure: playerFailure),
      );
      expect(
        () => validateYlPlayerState(
          YlPlayerState(status: YlPlaybackStatus.failed, failure: failure),
        ),
        throwsArgumentError,
      );
      expect(
        () => validateYlPlayerState(
          YlPlayerState(sessionId: const YlPlaybackSessionId('s')),
        ),
        throwsArgumentError,
      );
      for (final status in [
        YlPlaybackStatus.loading,
        YlPlaybackStatus.ready,
        YlPlaybackStatus.playing,
        YlPlaybackStatus.paused,
        YlPlaybackStatus.buffering,
        YlPlaybackStatus.completed,
      ]) {
        expect(
          () => validateYlPlayerState(YlPlayerState(status: status)),
          throwsArgumentError,
        );
        validateYlPlayerState(
          YlPlayerState(
            status: status,
            sessionId: const YlPlaybackSessionId('s'),
          ),
        );
      }
    },
  );

  test('state equality distinguishes each semantic field', () {
    final state = snapshot();
    for (final changed in [
      state.copyWith(sessionId: const YlPlaybackSessionId('session-2')),
      state.copyWith(status: YlPlaybackStatus.paused),
      state.copyWith(
        videoGeometry: state.videoGeometry!.copyWith(rotationDegrees: 90),
      ),
      state.copyWith(
        audioTracks: [const YlMediaTrack(id: 'a', kind: YlTrackKind.audio)],
      ),
      state.copyWith(
        videoTracks: [const YlMediaTrack(id: 'v', kind: YlTrackKind.video)],
      ),
      state.copyWith(engine: YlPlaybackEngine.managedFallback),
      state.copyWith(decoderIdentity: null),
      state.copyWith(metrics: const YlPlaybackMetrics(rebufferCount: 1)),
      state.copyWith(failure: null),
    ]) {
      expect(changed, isNot(state));
    }
  });

  test(
    'common metrics and playback state exclude obsolete capability and platform fields',
    () {
      final dynamic state = YlPlayerState();
      const dynamic metrics = YlPlaybackMetrics();
      expect(() => state.capabilities, throwsNoSuchMethodError);
      expect(() => metrics.androidDeviceTier, throwsNoSuchMethodError);
      expect(() => metrics.selectedVideoBitrate, throwsNoSuchMethodError);
    },
  );

  test(
    'event equality distinguishes session, revision, epoch and subclass payload',
    () {
      YlRetryScheduledEvent retry({
        String session = 's',
        int revision = 1,
        Duration occurredAt = Duration.zero,
        int index = 1,
        Duration delay = Duration.zero,
        YlFailure reason = failure,
      }) => YlRetryScheduledEvent(
        sessionId: YlPlaybackSessionId(session),
        revision: revision,
        occurredAt: occurredAt,
        retryIndex: index,
        delay: delay,
        failure: reason,
      );
      const otherFailure = YlFailure(
        category: YlFailureCategory.network,
        code: 'network.failed',
        message: secret,
        retryable: true,
        scope: YlFailureScope.session,
        diagnosticId: 'diagnostic-2',
      );
      final original = retry();
      expect(identical(original, retry()), isFalse);
      expect(original, retry());
      expect(original.hashCode, retry().hashCode);
      for (final changed in [
        retry(session: 's2'),
        retry(revision: 2),
        retry(occurredAt: const Duration(microseconds: 1)),
        retry(index: 2),
        retry(delay: const Duration(microseconds: 1)),
        retry(reason: otherFailure),
      ]) {
        expect(changed, isNot(original));
      }
      YlPlaybackEngineChangedEvent engineEvent({
        YlPlaybackEngine previous = YlPlaybackEngine.avPlayer,
        YlPlaybackEngine next = YlPlaybackEngine.managedFallback,
      }) => YlPlaybackEngineChangedEvent(
        sessionId: YlPlaybackSessionId('s'),
        revision: 1,
        occurredAt: Duration.zero,
        previousEngine: previous,
        engine: next,
      );
      expect(engineEvent(), engineEvent());
      expect(engineEvent().hashCode, engineEvent().hashCode);
      expect(
        engineEvent(previous: YlPlaybackEngine.unknown),
        isNot(engineEvent()),
      );
      expect(engineEvent(next: YlPlaybackEngine.media3), isNot(engineEvent()));
      YlPlaybackFailedEvent failed(YlFailure reason) => YlPlaybackFailedEvent(
        sessionId: YlPlaybackSessionId('s'),
        revision: 1,
        occurredAt: Duration.zero,
        failure: reason,
      );
      expect(failed(failure), failed(failure));
      expect(failed(failure).hashCode, failed(failure).hashCode);
      expect(failed(otherFailure), isNot(failed(failure)));
    },
  );

  test(
    'capability null clearing preserves evidence and limits independently',
    () {
      final caps = YlPlayerCapabilities(
        deviceProfile: 'ios',
        maxWidth: 1920,
        maxHeight: 1080,
        maxConcurrentVideoDecoders: 1,
        decoderEvidence: YlDecoderEvidence.hardwareAndSoftware,
      );
      final cleared = caps.copyWith(
        maxWidth: null,
        maxHeight: null,
        maxConcurrentVideoDecoders: null,
      );
      expect([
        cleared.maxWidth,
        cleared.maxHeight,
        cleared.maxConcurrentVideoDecoders,
      ], everyElement(isNull));
      expect(cleared.decoderEvidence, YlDecoderEvidence.hardwareAndSoftware);
      expect(caps.copyWith(maxHeight: null).maxWidth, 1920);
      expect(
        caps.copyWith(decoderEvidence: YlDecoderEvidence.hardwareOnly),
        isNot(caps),
      );
    },
  );
}
