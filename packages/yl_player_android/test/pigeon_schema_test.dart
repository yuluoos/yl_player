import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_android/src/pigeon/yl_player_android.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart'
    as public_api;

void main() {
  test('generated messages preserve the complete v2 transport shape', () {
    final failure = AndroidFailureMessage(
      category: AndroidFailureCategory.decoder,
      code: 'decoder.unavailable',
      message: 'Decoder unavailable',
      retryable: true,
      scope: AndroidFailureScope.session,
      diagnosticId: 'diag-1',
    );
    final source = AndroidSourceMessage(
      kind: AndroidSourceKind.network,
      locator: 'https://example.test/video.m3u8',
      intent: AndroidStreamIntent.live,
      format: AndroidMediaFormat.hls,
      request: AndroidHttpRequestMessage(
        headers: <String, String>{'accept': 'application/vnd.apple.mpegurl'},
        credentials: <String, String>{'authorization': 'Bearer private'},
      ),
      networkPolicy: AndroidNetworkPolicyMessage(
        kind: AndroidNetworkPolicyKind.managed,
        connectTimeoutMs: 1000,
        readTimeoutMs: 2000,
        maxRetries: 3,
        baseRetryDelayMs: 250,
        maxRetryDelayMs: 2000,
        maxRedirects: 5,
      ),
    );
    final loadOptions = AndroidLoadOptionsMessage(
      autoplay: true,
      startPositionMs: 500,
      bufferStrategy: AndroidBufferStrategyMessage(
        kind: AndroidBufferKind.bounded,
        minDurationMs: 1000,
        maxDurationMs: 5000,
        maxManagedBytes: 1048576,
      ),
      videoConstraints: AndroidVideoConstraintsMessage(
        maxWidth: 1920,
        maxHeight: 1080,
        maxBitrate: 8000000,
      ),
      decoderPolicyOverride: AndroidDecoderPolicy.hardwareRequired,
    );
    final create = AndroidCreateRequest(
      schemaMajor: 2,
      options: AndroidPlayerOptionsMessage(
        decoderPolicy: AndroidDecoderPolicy.hardwarePreferred,
        audioPolicy: AndroidAudioPolicy.pluginManagedMediaPlayback,
        positionUpdateIntervalMs: 250,
      ),
    );
    final state = AndroidStateMessage(
      loadRequestId: 'load-1',
      sessionId: 'session-1',
      revision: 7,
      sequence: 11,
      status: AndroidPlaybackStatus.playing,
      timeline: AndroidTimelineMessage(
        positionMs: 1200,
        durationMs: 60000,
        bufferedPositionMs: 4200,
        isSeekable: true,
        isLive: true,
        isAtLiveEdge: false,
        liveOffsetMs: 3000,
        dvrWindow: AndroidDvrWindowMessage(startMs: 0, endMs: 60000),
      ),
      geometry: AndroidVideoGeometryMessage(
        encodedSize: AndroidSizeMessage(width: 1920, height: 1080),
        displaySize: AndroidSizeMessage(width: 1920, height: 1080),
        pixelAspectRatio: 1,
        rotationDegrees: 0,
      ),
      audioTracks: <AndroidTrackMessage>[
        AndroidTrackMessage(
          id: 'audio-main',
          kind: AndroidTrackKind.audio,
          label: 'Main',
          language: 'en',
          codec: 'aac',
          bitrate: 128000,
          width: null,
          height: null,
          isSelected: true,
        ),
      ],
      videoTracks: <AndroidTrackMessage>[
        AndroidTrackMessage(
          id: 'video-main',
          kind: AndroidTrackKind.video,
          label: null,
          language: null,
          codec: 'h264',
          bitrate: 4000000,
          width: 1920,
          height: 1080,
          isSelected: true,
        ),
      ],
      engine: AndroidEngine.media3,
      decoderMode: AndroidDecoderMode.hardware,
      decoderIdentity: 'c2.vendor.decoder',
      metrics: AndroidMetricsMessage(
        loadToReadyMs: 100,
        loadToFirstFrameMs: 140,
        rebufferCount: 1,
        rebufferDurationMs: 20,
        droppedVideoFrames: 2,
        audioUnderruns: 0,
        estimatedBitrate: 5000000,
        managedBufferedDurationMs: 3000,
        managedBufferedBytes: 1000000,
        liveOffsetMs: 3000,
        reconnectCount: 1,
      ),
      failure: failure,
    );
    final delta = AndroidStateDeltaMessage(
      sessionId: 'session-1',
      previousRevision: 7,
      revision: 8,
      sequence: 12,
      positionMs: 1500,
      bufferedPositionMs: 4500,
      hasIsAtLiveEdge: true,
      isAtLiveEdge: true,
      hasLiveOffsetMs: true,
      liveOffsetMs: null,
      metrics: AndroidMetricsDeltaMessage(
        hasMediaClockPositionMs: false,
        hasLoadToReadyMs: false,
        loadToReadyMs: null,
        hasLoadToFirstFrameMs: false,
        loadToFirstFrameMs: null,
        hasRebufferCount: true,
        rebufferCount: 2,
        hasRebufferDurationMs: false,
        rebufferDurationMs: null,
        hasDroppedVideoFrames: false,
        droppedVideoFrames: null,
        hasAudioUnderruns: false,
        audioUnderruns: null,
        hasEstimatedBitrate: false,
        estimatedBitrate: null,
        hasManagedBufferedDurationMs: false,
        managedBufferedDurationMs: null,
        hasManagedBufferedBytes: true,
        managedBufferedBytes: null,
        hasLiveOffsetMs: false,
        liveOffsetMs: null,
        hasReconnectCount: false,
        reconnectCount: null,
      ),
    );

    final request = AndroidLoadRequest(
      loadRequestId: 'load-1',
      source: source,
      options: loadOptions,
    );
    final reply = AndroidLoadReply(
      loadRequestId: 'load-1',
      sessionId: 'session-1',
    );
    const codec = AndroidPlayerHostApi.pigeonChannelCodec;
    final decoded =
        codec.decodeMessage(codec.encodeMessage([request, reply, state]))!
            as List<Object?>;
    expect((decoded[0]! as AndroidLoadRequest).loadRequestId, 'load-1');
    expect((decoded[1]! as AndroidLoadReply).loadRequestId, 'load-1');
    expect((decoded[2]! as AndroidStateMessage).loadRequestId, 'load-1');
    expect(create.schemaMajor, 2);
    expect(source.request!.headers['accept'], 'application/vnd.apple.mpegurl');
    expect(loadOptions.bufferStrategy.kind, AndroidBufferKind.bounded);
    expect(state.failure, same(failure));
    expect(state.audioTracks.single.id, 'audio-main');
    expect(delta.metrics!.hasManagedBufferedBytes, isTrue);
    expect(delta.metrics!.managedBufferedBytes, isNull);
    expect(
      AndroidFailureCategory.values.map((value) => value.name),
      public_api.YlFailureCategory.values.map((value) => value.name),
    );
    expect(
      AndroidFailureScope.values.map((value) => value.name),
      public_api.YlFailureScope.values.map((value) => value.name),
    );
  });

  test(
    'generated Android types remain private to implementation libraries',
    () async {
      final workspaceRoot = Directory.current;
      final scratchRoot = Directory('${workspaceRoot.path}/.dart_tool');
      await scratchRoot.create(recursive: true);
      final scratch = await scratchRoot.createTemp('pigeon_privacy_test_');
      addTearDown(() => scratch.delete(recursive: true));

      final probe = File('${scratch.path}/public_barrels.dart');
      await probe.writeAsString('''
import 'package:yl_player_android/yl_player_android.dart' as androidPublic;
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart'
    as platformPublic;
import 'package:yl_player/yl_player.dart' as appPublic;

void main() {
  androidPublic.AndroidCreateRequest;
  platformPublic.AndroidCreateRequest;
  appPublic.AndroidCreateRequest;
}
''');
      final result = await Process.run('dart', <String>[
        'analyze',
        probe.path,
      ], workingDirectory: workspaceRoot.path);
      final diagnostics = '${result.stdout}\n${result.stderr}';

      expect(
        result.exitCode,
        isNonZero,
        reason: 'a public barrel unexpectedly exports AndroidCreateRequest',
      );
      for (final prefix in <String>[
        'androidPublic',
        'platformPublic',
        'appPublic',
      ]) {
        expect(diagnostics, contains("prefix '$prefix'"));
      }
      expect(
        RegExp('undefined_prefixed_name').allMatches(diagnostics),
        hasLength(3),
      );
      expect(diagnostics, isNot(contains('uri_does_not_exist')));
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
