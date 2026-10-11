import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/fake_player_platform.dart';
import 'support/matroska_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'discover the committed MKV, select its UID and render on media clock',
    () async {
      final dir = await Directory.systemTemp.createTemp('yl-embedded-');
      final file = await File('${dir.path}/media.mkv').writeAsBytes(mkv());
      final backend = FakePlatformPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
        enableTextSubtitles: true,
      );
      addTearDown(() async {
        await player.dispose();
        await dir.delete(recursive: true);
      });
      final pending = player.load(YlFileSource(file.path));
      const id = YlPlaybackSessionId('embedded');
      backend.commit(id);
      final session = await pending;
      await session.discoverEmbeddedSubtitles();
      final track = player.state.subtitles.tracks.single;
      expect(track.isExternal, false);
      expect(track.id, 'mkv:101');
      expect(player.state.subtitles.selectedTrackId, isNull);
      await session.selectSubtitleTrack(track.id);
      backend.emitState(
        backend.state.copyWith(
          revision: backend.state.revision + 1,
          status: YlPlaybackStatus.playing,
          timeline: const YlTimeline(position: Duration(milliseconds: 1500)),
        ),
      );
      backend.emitFirstFrame(id);
      expect(player.textSubtitleCues.single.text.toPlainText(), 'hello');
      await session.selectSubtitleTrack(null);
      expect(player.textSubtitleCues, isEmpty);
    },
  );
  group('session lifecycle', () {
    late Directory dir;
    late File file;
    late FakePlatformPlayer backend;
    late YlPlayerController player;
    late YlPlaybackSession session;
    const id = YlPlaybackSessionId('embedded');
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('yl-embedded-session-');
      file = await File('${dir.path}/media.mkv').writeAsBytes(mkv());
      backend = FakePlatformPlayer();
      player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
        enableTextSubtitles: true,
      );
      final pending = player.load(YlFileSource(file.path));
      backend.commit(id);
      session = await pending;
      await session.discoverEmbeddedSubtitles();
      await session.selectSubtitleTrack('mkv:101');
    });
    tearDown(() async {
      await player.dispose();
      await dir.delete(recursive: true);
    });
    void position(int ms) {
      backend.emitState(
        backend.state.copyWith(
          revision: backend.state.revision + 1,
          status: YlPlaybackStatus.playing,
          timeline: YlTimeline(position: Duration(milliseconds: ms)),
          videoGeometry: const YlVideoGeometry(
            encodedSize: YlPixelSize(300, 200),
            displaySize: YlPixelSize(300, 200),
          ),
        ),
      );
    }

    test('offset and seek clear/requery the actual container cue', () async {
      position(1500);
      backend.emitFirstFrame(id);
      expect(player.textSubtitleCues, hasLength(1));
      backend.delayCommand('seekTo', id);
      final seeking = session.seekTo(const Duration(seconds: 5));
      expect(player.textSubtitleCues, isEmpty);
      backend.completeCommand('seekTo', id);
      await seeking;
      expect(player.textSubtitleCues, isEmpty);
      position(5000);
      expect(player.textSubtitleCues, isEmpty);
      await session.setSubtitleOffset(const Duration(milliseconds: -500));
      position(500);
      expect(player.textSubtitleCues, hasLength(1));
      await session.setSubtitleOffset(const Duration(milliseconds: 500));
      position(1000);
      expect(player.textSubtitleCues, isEmpty);
      position(1500);
      expect(player.textSubtitleCues, hasLength(1));
    });
    test('new Load starts off and stale discovery cannot publish', () async {
      final pending = session.discoverEmbeddedSubtitles();
      final rejected = expectLater(pending, throwsA(isA<YlPlayerException>()));
      final next = player.load(YlFileSource(file.path));
      backend.commit(const YlPlaybackSessionId('new'));
      await next;
      await rejected;
      expect(player.state.subtitles.tracks, isEmpty);
      expect(player.state.subtitles.offset, Duration.zero);
      await expectLater(
        session.discoverEmbeddedSubtitles(),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.sessionStale,
          ),
        ),
      );
    });
    test('Stop cancels discovery and removes old track/selection', () async {
      final pending = session.discoverEmbeddedSubtitles();
      final rejected = expectLater(pending, throwsA(isA<YlPlayerException>()));
      await player.stop();
      await rejected;
      expect(player.state.subtitles.tracks, isEmpty);
      expect(player.textSubtitleCues, isEmpty);
    });
    test('Dispose cancels pending scan', () async {
      final pending = session.discoverEmbeddedSubtitles();
      final rejected = expectLater(pending, throwsA(isA<YlPlayerException>()));
      await player.dispose();
      await rejected;
      expect(player.textSubtitleCues, isEmpty);
    });
    testWidgets(
      'YlPlayerView renders discovered text and clears off/seek/unmount',
      (tester) async {
        position(1500);
        backend.emitFirstFrame(id);
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 300,
              height: 200,
              child: YlPlayerView(controller: player),
            ),
          ),
        );
        expect(find.text('hello', findRichText: true), findsOneWidget);
        await session.selectSubtitleTrack(null);
        await tester.pump();
        expect(find.text('hello', findRichText: true), findsNothing);
        await session.selectSubtitleTrack('mkv:101');
        await tester.pump();
        expect(find.text('hello', findRichText: true), findsOneWidget);
        backend.delayCommand('seekTo', id);
        final seeking = session.seekTo(const Duration(seconds: 5));
        await tester.pump();
        expect(find.text('hello', findRichText: true), findsNothing);
        backend.completeCommand('seekTo', id);
        await seeking;
        position(5000);
        await tester.pump();
        expect(find.text('hello', findRichText: true), findsNothing);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  });
  test(
    'default controller rejects discovery without opted-in ownership',
    () async {
      final backend = FakePlatformPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      addTearDown(player.dispose);
      final pending = player.load(const YlFileSource('/media.mkv'));
      backend.commit(const YlPlaybackSessionId('old'));
      final session = await pending;
      await expectLater(
        session.discoverEmbeddedSubtitles(),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.policyUnsupported,
          ),
        ),
      );
    },
  );
}
