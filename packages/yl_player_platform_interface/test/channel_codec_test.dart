import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_channel.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  test('encodes configuration, source, and quality with stable keys', () {
    final source = YlMediaSource.network(
      Uri.parse('https://media.test/live.m3u8'),
      isLive: true,
      formatHint: YlFormatHint.hls,
      headers: const <String, String>{'Referer': 'https://media.test/'},
    );

    final configuration = encodeYlConfiguration(
      const YlPlayerConfiguration(
        decoderPolicy: YlDecoderPolicy.hardwareOnly,
        networkPolicy: YlNetworkPolicy(maxRetries: 2),
      ),
    );

    expect(configuration['decoderPolicy'], 'hardwareOnly');
    expect((configuration['network'] as Map<String, Object?>)['maxRetries'], 2);
    expect(encodeYlSource(source)['formatHint'], 'hls');
    expect(
      encodeYlQualityConstraint(
        const YlQualityConstraint(maxWidth: 1280),
      )['maxWidth'],
      1280,
    );
  });

  test('decodes a complete state snapshot', () {
    final state = decodeYlState(<String, Object?>{
      'status': 'playing',
      'positionMs': 1500,
      'durationMs': 10000,
      'bufferedPositionMs': 4000,
      'isLive': true,
      'isSeekable': true,
      'isAtLiveEdge': false,
      'liveOffsetMs': 3000,
      'dvrStartMs': 100,
      'dvrEndMs': 9000,
      'videoWidth': 1920,
      'videoHeight': 1080,
      'engine': 'media3',
      'isHardwareDecoding': true,
      'decoderName': 'c2.vendor.avc.decoder',
      'audioTracks': <Object?>[
        <String, Object?>{
          'id': 'audio-1',
          'kind': 'audio',
          'language': 'zh',
          'isSelected': true,
        },
      ],
      'videoTracks': <Object?>[],
      'capabilities': <String, Object?>{
        'hardwareVideoCodecs': <String>['video/avc'],
        'supportedFormats': <String>['hls'],
        'maxConcurrentVideoDecoders': 1,
      },
      'metrics': <String, Object?>{
        'openDurationMs': 50,
        'droppedVideoFrames': 3,
        'rebufferCount': 2,
      },
    });

    expect(state.status, YlPlaybackStatus.playing);
    expect(state.position, const Duration(milliseconds: 1500));
    expect(state.dvrWindow?.start, const Duration(milliseconds: 100));
    expect(state.videoSize?.width, 1920);
    expect(state.engine, YlPlaybackEngine.media3);
    expect(state.audioTracks.single.language, 'zh');
    expect(state.capabilities?.hardwareVideoCodecs, {'video/avc'});
    expect(state.metrics.openDuration, const Duration(milliseconds: 50));
    expect(state.metrics.droppedVideoFrames, 3);
  });

  test('merges only continuous state and dynamic metrics', () {
    final capabilities = YlPlayerCapabilities(
      supportedFormats: <YlFormatHint>{YlFormatHint.hls},
    );
    final current = YlPlayerState(
      status: YlPlaybackStatus.playing,
      position: const Duration(seconds: 1),
      liveOffset: const Duration(seconds: 2),
      decoderName: 'decoder',
      capabilities: capabilities,
      metrics: const YlPlaybackMetrics(
        rebufferCount: 2,
        droppedVideoFrames: 3,
        estimatedBitrate: 1000,
      ),
    );

    final merged = mergeYlStateDelta(current, <String, Object?>{
      'positionMs': 1750,
      'bufferedPositionMs': 5000,
      'liveOffsetMs': null,
      'isAtLiveEdge': true,
      'status': 'error',
      'decoderName': 'wrong',
      'capabilities': null,
      'metrics': <String, Object?>{
        'droppedVideoFrames': 4,
        'bufferedDurationMs': 3250,
        'estimatedBitrate': null,
      },
    });

    expect(merged.position, const Duration(milliseconds: 1750));
    expect(merged.bufferedPosition, const Duration(seconds: 5));
    expect(merged.liveOffset, isNull);
    expect(merged.isAtLiveEdge, isTrue);
    expect(merged.status, YlPlaybackStatus.playing);
    expect(merged.decoderName, 'decoder');
    expect(merged.capabilities, same(capabilities));
    expect(merged.metrics.rebufferCount, 2);
    expect(merged.metrics.droppedVideoFrames, 4);
    expect(merged.metrics.bufferedDuration, const Duration(milliseconds: 3250));
    expect(merged.metrics.estimatedBitrate, isNull);
  });

  test('defensively decodes malformed values without throwing', () {
    expect(() => decodeYlState('not-a-map'), returnsNormally);
    final state = decodeYlState(<String, Object?>{
      'status': 'future-status',
      'positionMs': double.infinity,
      'engine': 7,
      'audioTracks': <Object?>['bad-track'],
      'metrics': <String, Object?>{'droppedVideoFrames': double.nan},
    });

    expect(state.status, YlPlaybackStatus.idle);
    expect(state.position, Duration.zero);
    expect(state.engine, YlPlaybackEngine.unknown);
    expect(state.audioTracks, isEmpty);
    expect(state.metrics.droppedVideoFrames, 0);
  });

  test('does not accept the legacy droppedFrames metric key', () {
    final state = decodeYlState(<String, Object?>{
      'metrics': <String, Object?>{'droppedFrames': 9},
    });

    expect(state.metrics.droppedVideoFrames, 0);
  });

  test('decodes events and platform exceptions with stable fallbacks', () {
    final event = decodeYlEvent(<String, Object?>{
      'type': 'retry',
      'attempt': 2,
      'delayMs': 500,
      'error': <String, Object?>{
        'category': 'network',
        'code': 'network.retry',
        'message': 'Retrying.',
      },
    });
    final error = decodeYlPlatformException(
      PlatformException(code: 'platform.failure'),
      platform: 'android',
    );

    expect(event, isA<YlRetryEvent>());
    expect((event! as YlRetryEvent).attempt, 2);
    expect(error.code, 'platform.failure');
    expect(error.category, YlPlayerErrorCategory.internal);
  });
}
