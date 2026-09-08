import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_apple/src/pigeon/yl_player_apple.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart'
    as public_api;

void main() {
  test('generated codec preserves the complete Apple v2 transport', () {
    final failure = AppleFailureMessage(
      category: AppleFailureCategory.decoder,
      code: 'decoder.unavailable',
      message: 'Decoder unavailable',
      retryable: true,
      scope: AppleFailureScope.session,
      diagnosticId: 'diag-1',
    );
    final source = AppleSourceMessage(
      kind: AppleSourceKind.network,
      locator: 'https://example.test/video.m3u8',
      intent: AppleStreamIntent.live,
      format: AppleMediaFormat.hls,
      request: AppleHttpRequestMessage(
        headers: <String, String>{'accept': 'application/vnd.apple.mpegurl'},
        credentials: <String, String>{'authorization': 'Bearer private'},
      ),
      networkPolicy: AppleNetworkPolicyMessage(
        kind: AppleNetworkPolicyKind.managed,
        connectTimeoutMs: 1000,
        readTimeoutMs: 2000,
        maxRetries: 3,
        baseRetryDelayMs: 250,
        maxRetryDelayMs: 2000,
        maxRedirects: 5,
      ),
    );
    final loadOptions = AppleLoadOptionsMessage(
      autoplay: true,
      startPositionMs: 500,
      bufferStrategy: AppleBufferStrategyMessage(
        kind: AppleBufferKind.bounded,
        minDurationMs: 1000,
        maxDurationMs: 5000,
        maxManagedBytes: 1048576,
      ),
      videoConstraints: AppleVideoConstraintsMessage(
        maxWidth: 1920,
        maxHeight: 1080,
        maxBitrate: 8000000,
      ),
      decoderPolicyOverride: AppleDecoderPolicy.hardwareRequired,
    );
    final createRequest = AppleCreateRequest(
      schemaMajor: 2,
      options: ApplePlayerOptionsMessage(
        decoderPolicy: AppleDecoderPolicy.hardwarePreferred,
        audioPolicy: AppleAudioPolicy.pluginManagedMediaPlayback,
        positionUpdateIntervalMs: 250,
      ),
    );
    final state = AppleStateMessage(
      loadRequestId: 'load-1',
      sessionId: 'session-1',
      revision: 7,
      sequence: 11,
      status: ApplePlaybackStatus.playing,
      timeline: AppleTimelineMessage(
        positionMs: 1200,
        durationMs: 60000,
        bufferedPositionMs: 4200,
        isSeekable: true,
        isLive: true,
        isAtLiveEdge: false,
        liveOffsetMs: 3000,
        dvrWindow: AppleDvrWindowMessage(startMs: 0, endMs: 60000),
      ),
      geometry: AppleVideoGeometryMessage(
        encodedSize: AppleSizeMessage(width: 1920, height: 1080),
        displaySize: AppleSizeMessage(width: 1920, height: 1080),
        pixelAspectRatio: 1,
        rotationDegrees: 0,
      ),
      audioTracks: <AppleTrackMessage>[
        AppleTrackMessage(
          id: 'audio-main',
          kind: AppleTrackKind.audio,
          label: 'Main',
          language: 'en',
          codec: 'aac',
          bitrate: 128000,
          width: null,
          height: null,
          isSelected: true,
        ),
      ],
      videoTracks: <AppleTrackMessage>[
        AppleTrackMessage(
          id: 'video-main',
          kind: AppleTrackKind.video,
          label: null,
          language: null,
          codec: 'h264',
          bitrate: 4000000,
          width: 1920,
          height: 1080,
          isSelected: true,
        ),
      ],
      engine: AppleEngine.avPlayer,
      decoderMode: AppleDecoderMode.hardware,
      decoderIdentity: 'com.apple.videotoolbox',
      metrics: AppleMetricsMessage(
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
    final capabilities = AppleCapabilitiesMessage(
      deviceProfile: 'apple-silicon',
      availableEngines: <AppleEngine>[
        AppleEngine.avPlayer,
        AppleEngine.managedFallback,
      ],
      decoderEvidence: AppleDecoderEvidence.hardwareAndSoftware,
      maxConcurrentVideoDecoders: 4,
      maxWidth: 3840,
      maxHeight: 2160,
      hardwareVideoCodecs: <String>['h264', 'hevc'],
      supportedOperations: <ApplePlayerOperation>[
        ApplePlayerOperation.seek,
        ApplePlayerOperation.seekToLiveEdge,
        ApplePlayerOperation.audioTrackSelection,
      ],
    );
    AppleCreateReply createReply(ApplePlatform platform) => AppleCreateReply(
      schemaMajor: 2,
      spiMajor: 2,
      channelSuffix: 'player-1',
      textureId: 42,
      platform: platform,
      implementationName: 'yl_player_apple',
      implementationVersion: '0.2.0-dev.1',
      capabilities: capabilities,
      initialState: state,
    );
    final loadRequest = AppleLoadRequest(
      loadRequestId: 'load-1',
      source: source,
      options: loadOptions,
    );
    final loadReply = AppleLoadReply(
      loadRequestId: 'load-1',
      sessionId: 'session-1',
    );
    final delta = AppleStateDeltaMessage(
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
      metrics: AppleMetricsDeltaMessage(
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
    final firstFrame = AppleFirstFrameMessage(
      sessionId: 'session-1',
      revision: 8,
      sequence: 13,
      occurredAtMs: 9000,
    );
    final retry = AppleRetryScheduledMessage(
      sessionId: 'session-1',
      revision: 9,
      sequence: 14,
      occurredAtMs: 9100,
      retryIndex: 1,
      delayMs: 250,
      failure: failure,
    );
    final engineChanged = AppleEngineChangedMessage(
      sessionId: 'session-1',
      revision: 10,
      sequence: 15,
      occurredAtMs: 9200,
      previousEngine: AppleEngine.avPlayer,
      engine: AppleEngine.managedFallback,
    );
    final playbackFailed = ApplePlaybackFailedMessage(
      sessionId: 'session-1',
      revision: 11,
      sequence: 16,
      occurredAtMs: 9300,
      failure: failure,
    );

    const codec = ApplePlayerHostApi.pigeonChannelCodec;
    final decoded =
        codec.decodeMessage(
              codec.encodeMessage(<Object?>[
                createRequest,
                createReply(ApplePlatform.ios),
                createReply(ApplePlatform.macos),
                loadRequest,
                loadReply,
                state,
                delta,
                firstFrame,
                retry,
                engineChanged,
                playbackFailed,
                failure,
              ]),
            )!
            as List<Object?>;

    expect(
      (decoded[0]! as AppleCreateRequest).options.positionUpdateIntervalMs,
      250,
    );
    expect((decoded[1]! as AppleCreateReply).platform, ApplePlatform.ios);
    expect((decoded[2]! as AppleCreateReply).platform, ApplePlatform.macos);
    expect((decoded[3]! as AppleLoadRequest).loadRequestId, 'load-1');
    expect(
      (decoded[3]! as AppleLoadRequest).source.request!.credentials,
      <String, String>{'authorization': 'Bearer private'},
    );
    expect((decoded[4]! as AppleLoadReply).loadRequestId, 'load-1');
    expect((decoded[5]! as AppleStateMessage).loadRequestId, 'load-1');
    expect(
      (decoded[5]! as AppleStateMessage).audioTracks.single.id,
      'audio-main',
    );
    expect(
      (decoded[6]! as AppleStateDeltaMessage).metrics!.hasManagedBufferedBytes,
      isTrue,
    );
    expect(
      (decoded[6]! as AppleStateDeltaMessage).metrics!.managedBufferedBytes,
      isNull,
    );
    expect((decoded[7]! as AppleFirstFrameMessage).occurredAtMs, 9000);
    expect((decoded[8]! as AppleRetryScheduledMessage).retryIndex, 1);
    expect(
      (decoded[9]! as AppleEngineChangedMessage).engine,
      AppleEngine.managedFallback,
    );
    expect(
      (decoded[10]! as ApplePlaybackFailedMessage).failure.code,
      'decoder.unavailable',
    );
    expect((decoded[11]! as AppleFailureMessage).diagnosticId, 'diag-1');
    final categoryPairs =
        <(AppleFailureCategory, public_api.YlFailureCategory)>[
          (
            AppleFailureCategory.cancelled,
            public_api.YlFailureCategory.cancelled,
          ),
          (
            AppleFailureCategory.unsupported,
            public_api.YlFailureCategory.unsupported,
          ),
          (AppleFailureCategory.source, public_api.YlFailureCategory.source),
          (AppleFailureCategory.network, public_api.YlFailureCategory.network),
          (
            AppleFailureCategory.container,
            public_api.YlFailureCategory.container,
          ),
          (AppleFailureCategory.decoder, public_api.YlFailureCategory.decoder),
          (AppleFailureCategory.render, public_api.YlFailureCategory.render),
          (
            AppleFailureCategory.resource,
            public_api.YlFailureCategory.resource,
          ),
          (
            AppleFailureCategory.protocolFailure,
            public_api.YlFailureCategory.protocol,
          ),
          (
            AppleFailureCategory.platform,
            public_api.YlFailureCategory.platform,
          ),
          (
            AppleFailureCategory.internalFailure,
            public_api.YlFailureCategory.internal,
          ),
        ];
    expect(categoryPairs.map((pair) => pair.$1.index), <int>[
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
      10,
    ]);
    expect(categoryPairs.map((pair) => pair.$2.index), <int>[
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
      10,
    ]);
    expect(
      categoryPairs.map((pair) => '${pair.$1.name}->${pair.$2.name}'),
      <String>[
        'cancelled->cancelled',
        'unsupported->unsupported',
        'source->source',
        'network->network',
        'container->container',
        'decoder->decoder',
        'render->render',
        'resource->resource',
        'protocolFailure->protocol',
        'platform->platform',
        'internalFailure->internal',
      ],
    );
    expect(
      AppleFailureScope.values.map((value) => value.name),
      public_api.YlFailureScope.values.map((value) => value.name),
    );
  });

  test(
    'generated Apple types remain private to implementation libraries',
    () async {
      final workspaceRoot = Directory.current;
      final scratchRoot = Directory('${workspaceRoot.path}/.dart_tool');
      await scratchRoot.create(recursive: true);
      final scratch = await scratchRoot.createTemp('pigeon_privacy_test_');
      addTearDown(() => scratch.delete(recursive: true));

      final probe = File('${scratch.path}/public_barrels.dart');
      await probe.writeAsString('''
import 'package:yl_player_apple/yl_player_apple.dart' as applePublic;
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart'
    as platformPublic;
import 'package:yl_player/yl_player.dart' as appPublic;

void main() {
  applePublic.AppleCreateRequest;
  platformPublic.AppleCreateRequest;
  appPublic.AppleCreateRequest;
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
        reason: 'a public barrel unexpectedly exports AppleCreateRequest',
      );
      for (final prefix in <String>[
        'applePublic',
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
