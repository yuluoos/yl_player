import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  group('YlMediaSource', () {
    test('network source snapshots headers and records live intent', () {
      final headers = <String, String>{'Referer': 'https://example.test'};

      final source = YlMediaSource.network(
        Uri.parse('https://media.test/live.m3u8'),
        isLive: true,
        formatHint: YlFormatHint.hls,
        headers: headers,
      );
      headers['Referer'] = 'https://changed.test';

      expect(source.kind, YlMediaSourceKind.network);
      expect(source.isLive, isTrue);
      expect(source.formatHint, YlFormatHint.hls);
      expect(source.headers['Referer'], 'https://example.test');
      expect(
        () => source.headers['Authorization'] = 'secret',
        throwsUnsupportedError,
      );
    });

    test('network source rejects non-HTTP URI', () {
      expect(
        () => YlMediaSource.network(Uri.parse('file:///video.mp4')),
        throwsArgumentError,
      );
    });

    test('file and content factories assign the correct source kind', () {
      final file = YlMediaSource.file('/media/video.mp4');
      final content = YlMediaSource.content(
        Uri.parse('content://library/video/42'),
      );

      expect(file.kind, YlMediaSourceKind.file);
      expect(file.uri, Uri.file('/media/video.mp4'));
      expect(content.kind, YlMediaSourceKind.content);
    });
  });

  group('YlPlayerState', () {
    test('copyWith preserves fields that are not supplied', () {
      final initial = YlPlayerState(
        status: YlPlaybackStatus.playing,
        position: Duration(seconds: 4),
        isLive: true,
      );

      final changed = initial.copyWith(position: const Duration(seconds: 5));

      expect(changed.status, YlPlaybackStatus.playing);
      expect(changed.position, const Duration(seconds: 5));
      expect(changed.isLive, isTrue);
    });

    test('copyWith can explicitly clear nullable values', () {
      const error = YlPlayerError(
        category: YlPlayerErrorCategory.network,
        code: 'network.timeout',
        message: 'Timed out.',
      );
      final initial = YlPlayerState(
        status: YlPlaybackStatus.error,
        duration: Duration(minutes: 1),
        error: error,
      );

      final changed = initial.copyWith(duration: null, error: null);

      expect(changed.duration, isNull);
      expect(changed.error, isNull);
    });

    test('track lists are immutable snapshots', () {
      final tracks = <YlMediaTrack>[
        const YlMediaTrack(id: 'audio-1', kind: YlTrackKind.audio),
      ];
      final state = YlPlayerState(audioTracks: tracks);
      tracks.clear();

      expect(state.audioTracks, hasLength(1));
      expect(
        () => state.audioTracks.add(
          const YlMediaTrack(id: 'audio-2', kind: YlTrackKind.audio),
        ),
        throwsUnsupportedError,
      );
    });
  });

  test('player error keeps a stable category and code', () {
    const error = YlPlayerError(
      category: YlPlayerErrorCategory.decoderUnsupported,
      code: 'decoder.profile_unsupported',
      message: 'The selected stream is not supported.',
    );

    expect(error.category, YlPlayerErrorCategory.decoderUnsupported);
    expect(error.toString(), contains('decoder.profile_unsupported'));
  });

  test('capabilities snapshot freezes codec and format sets', () {
    final codecs = <String>{'video/avc'};
    final formats = <YlFormatHint>{YlFormatHint.hls};
    final capabilities = YlPlayerCapabilities(
      hardwareVideoCodecs: codecs,
      supportedFormats: formats,
    );
    codecs.add('video/hevc');
    formats.add(YlFormatHint.matroska);

    expect(capabilities.hardwareVideoCodecs, {'video/avc'});
    expect(capabilities.supportedFormats, {YlFormatHint.hls});
  });

  test('playback metrics expose optional Android diagnostics', () {
    const metrics = YlPlaybackMetrics(
      androidDeviceTier: 'constrained',
      targetBufferBytes: 24 * 1024 * 1024,
      adaptiveDowngradeCount: 1,
      surfaceRebuildCount: 2,
      selectedVideoBitrate: 2500000,
    );

    expect(metrics.androidDeviceTier, 'constrained');
    expect(metrics.targetBufferBytes, 24 * 1024 * 1024);
    expect(metrics.adaptiveDowngradeCount, 1);
    expect(metrics.surfaceRebuildCount, 2);
    expect(metrics.selectedVideoBitrate, 2500000);
  });

  test('configuration exposes safe TVBox defaults', () {
    const configuration = YlPlayerConfiguration();

    expect(configuration.bufferMode, YlBufferMode.automatic);
    expect(configuration.decoderPolicy, YlDecoderPolicy.preferHardware);
    expect(configuration.networkPolicy.maxRetries, 3);
    expect(
      configuration.positionEventInterval,
      const Duration(milliseconds: 250),
    );
  });
}
