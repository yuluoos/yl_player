import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

YlExternalSubtitle external({
  String id = 's',
  YlMediaSource? source,
  YlSubtitleFormat format = YlSubtitleFormat.srt,
  YlMediaSource? companion,
}) => YlExternalSubtitle(
  id: id,
  source: source ?? const YlFileSource('/sub.srt'),
  format: format,
  companionSource: companion,
);

const track = YlSubtitleTrack(
  id: 'en-main',
  format: YlSubtitleFormat.webvtt,
  language: 'en',
  role: 'main',
  contentId: 'content',
);

void main() {
  test('defaults, state copy and value semantics preserve old snapshots', () {
    final off = YlSubtitleState();
    expect(YlPlayerState().subtitles, off);
    final active = YlSubtitleState(
      tracks: [track],
      selectedTrackId: track.id,
      offset: const Duration(milliseconds: -250),
    );
    final state = YlPlayerState(
      sessionId: const YlPlaybackSessionId('s'),
      status: YlPlaybackStatus.ready,
      subtitles: active,
    );
    validateYlPlayerState(state);
    expect(state.copyWith(), state);
    expect(state.copyWith().hashCode, state.hashCode);
    expect(state.copyWith(subtitles: off), isNot(state));
    expect(active.copyWith(), active);
    expect(active.copyWith(selectedTrackId: null).selectedTrackId, isNull);
    expect(active.copyWith(offset: Duration.zero).offset, Duration.zero);
    expect(() => active.copyWith(selectedTrackId: 123), throwsArgumentError);
  });

  test(
    'snapshots copy their lists and preserve same-language distinct roles',
    () {
      const commentary = YlSubtitleTrack(
        id: 'en-commentary',
        format: YlSubtitleFormat.webvtt,
        language: 'en',
        role: 'commentary',
        contentId: 'other',
      );
      final tracks = [track, commentary];
      final state = YlSubtitleState(
        tracks: tracks,
        selectedTrackId: commentary.id,
      );
      tracks.clear();
      validateYlSubtitleState(state);
      expect(state.tracks, hasLength(2));
      expect(() => state.tracks.clear(), throwsUnsupportedError);
      expect(track, isNot(commentary));
      expect(
        track,
        const YlSubtitleTrack(
          id: 'en-main',
          format: YlSubtitleFormat.webvtt,
          language: 'en',
          role: 'main',
          contentId: 'content',
        ),
      );
    },
  );

  test(
    'duplicate ids, missing selected ids and idle subtitles are rejected',
    () {
      for (final state in [
        YlSubtitleState(tracks: [track, track]),
        YlSubtitleState(tracks: [track], selectedTrackId: 'missing'),
        YlSubtitleState(selectedTrackId: ''),
        YlSubtitleState(
          tracks: List.generate(
            129,
            (i) => YlSubtitleTrack(id: '$i', format: YlSubtitleFormat.srt),
          ),
        ),
      ]) {
        expect(() => validateYlSubtitleState(state), throwsArgumentError);
      }
      expect(
        () => validateYlPlayerState(
          YlPlayerState(subtitles: YlSubtitleState(tracks: [track])),
        ),
        throwsArgumentError,
      );
      expect(
        () => validateYlPlayerState(
          YlPlayerState(
            subtitles: YlSubtitleState(offset: const Duration(seconds: 1)),
          ),
        ),
        throwsArgumentError,
      );
    },
  );

  test('metadata and offset boundaries have release-safe validation', () {
    for (final id in [
      '',
      'x\nsecret',
      'x\u007f',
      List.filled(1025, 'x').join(),
    ]) {
      expect(() => validateYlSubtitleTrackId(id), throwsArgumentError);
    }
    for (final field in ['', List.filled(129, 'x').join(), 'en\nsecret']) {
      expect(
        () => validateYlSubtitleState(
          YlSubtitleState(
            tracks: [
              YlSubtitleTrack(
                id: 'a',
                format: YlSubtitleFormat.srt,
                language: field,
              ),
            ],
          ),
        ),
        throwsArgumentError,
      );
    }
    for (final offset in [
      const Duration(microseconds: 1),
      const Duration(days: 7, milliseconds: 1),
      const Duration(days: -7, milliseconds: -1),
    ]) {
      expect(() => validateYlSubtitleOffset(offset), throwsArgumentError);
    }
    for (final offset in [
      const Duration(days: -7),
      Duration.zero,
      const Duration(days: 7),
    ]) {
      validateYlSubtitleOffset(offset);
    }
  });

  test(
    'external file/http sources retain declared request policy and equality',
    () {
      final request = YlHttpRequest(credentials: {'Authorization': 'secret'});
      final source = YlNetworkSource(
        Uri.parse('https://example.test/sub.vtt?token=secret'),
        request: request,
        networkPolicy: const YlNetworkPolicy.managed(maxRetries: 1),
      );
      final value = external(source: source);
      validateYlExternalSubtitles([value]);
      expect(value.source, same(source));
      expect(value, external(source: source));
      expect(value.hashCode, external(source: source).hashCode);
      expect(value.toString(), isNot(contains('secret')));
      validateYlExternalSubtitles([external()]);
    },
  );

  test(
    'unsupported media semantics and unsafe requests are rejected before dispatch',
    () {
      for (final source in <YlMediaSource>[
        const YlFileSource('relative.srt'),
        const YlFileSource('/file', format: YlMediaFormat.mp4),
        YlNetworkSource(Uri.parse('rtmp://example.test/app/stream')),
        YlNetworkSource(
          Uri.parse('https://example.test/file'),
          intent: YlStreamIntent.live,
        ),
        YlAndroidContentSource(Uri.parse('content://provider/sub')),
        YlNetworkSource(
          Uri.parse('https://example.test/file'),
          request: YlHttpRequest(headers: {'Authorization': 'secret'}),
        ),
        YlNetworkSource(
          Uri.parse('https://example.test/file'),
          networkPolicy: const YlNetworkPolicy.managed(maxRetries: -1),
        ),
        YlFileSource('/${List.filled(8192, 'x').join()}'),
      ]) {
        expect(
          () => validateYlExternalSubtitles([external(source: source)]),
          throwsArgumentError,
        );
      }
    },
  );

  test('VobSub pair is explicit, bounded and independently validated', () {
    validateYlExternalSubtitles([
      external(
        format: YlSubtitleFormat.vobsub,
        companion: const YlFileSource('/sub.idx'),
      ),
    ]);
    expect(
      () => validateYlExternalSubtitles([
        external(format: YlSubtitleFormat.vobsub),
      ]),
      throwsArgumentError,
    );
    expect(
      () => validateYlExternalSubtitles([
        external(companion: const YlFileSource('/sub.idx')),
      ]),
      throwsArgumentError,
    );
    expect(
      () => validateYlExternalSubtitles([
        external(
          format: YlSubtitleFormat.vobsub,
          companion: const YlFileSource('relative.idx'),
        ),
      ]),
      throwsArgumentError,
    );
  });

  test('external ids, list limit and all diagnostic strings are safe', () {
    expect(
      () => validateYlExternalSubtitles([external(), external()]),
      throwsArgumentError,
    );
    expect(
      () => validateYlExternalSubtitles(
        List.generate(33, (i) => external(id: '$i')),
      ),
      throwsArgumentError,
    );
    final secretTrack = const YlSubtitleTrack(
      id: 'private-id',
      format: YlSubtitleFormat.srt,
      label: 'private-label',
      language: 'private-language',
      role: 'private-role',
      contentId: 'private-content',
    );
    final state = YlSubtitleState(
      tracks: [secretTrack],
      selectedTrackId: secretTrack.id,
    );
    expect(
      '$secretTrack $state ${YlPlayerState(subtitles: state)}',
      isNot(contains('private')),
    );
    try {
      validateYlExternalSubtitles([external(id: 'secret\n')]);
      fail('invalid id accepted');
    } on ArgumentError catch (error) {
      expect('$error', isNot(contains('secret')));
    }
  });

  test('new capabilities append without changing existing enum ordinals', () {
    expect(YlTrackKind.values, [YlTrackKind.audio, YlTrackKind.video]);
    expect(YlPlayerOperation.videoTrackSelection.index, 7);
    expect(YlPlayerOperation.externalSubtitles.index, 8);
    expect(YlPlayerOperation.subtitleTrackSelection.index, 9);
    expect(YlPlayerOperation.subtitleOffset.index, 10);
  });
}
