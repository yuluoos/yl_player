import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/matroska_fixture.dart';
import 'support/embedded_pgs_fixture.dart';
import 'support/pgs_fixture.dart';
import 'package:yl_player/src/subtitles/pgs_overlay.dart';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'support/range_server.dart';
import 'support/fake_player_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpOverrides? previous;
  late RangeServer server;
  late FakePlatformPlayer backend;
  late YlPlayerController player;
  late YlPlaybackSession session;
  const id = YlPlaybackSessionId('network-matroska-pgs');
  setUp(() async {
    previous = HttpOverrides.current;
    HttpOverrides.global = null;
    server = await RangeServer.start(
      mkv(
        tracks: [
          ...track(codec: 'S_HDMV/PGS'),
          ...track(number: 2, uid: 102, forced: true),
        ],
        extra: element(0xec, List.filled(40000, 0)),
        clusters: cluster([
          for (final p in pgsPackets(pgsFixture()))
            ...pgsBlock(p.bytes, time: p.time),
          ...block(number: 2, time: 1000, text: 'forced'),
        ], time: 0),
      ),
    );
    backend = FakePlatformPlayer();
    player = await YlPlayerController.create(
      platform: FakePlayerPlatform(backend),
      enableTextSubtitles: true,
    );
    final pending = player.load(
      YlNetworkSource(
        server.uri,
        networkPolicy: const YlNetworkPolicy.managed(maxRetries: 0),
        request: YlHttpRequest(credentials: {'Authorization': 'owned secret'}),
      ),
    );
    backend.commit(id);
    session = await pending;
  });
  tearDown(() async {
    await player.dispose();
    await server.close();
    HttpOverrides.global = previous;
  });
  void position(int ms) => backend.emitState(
    backend.state.copyWith(
      revision: backend.state.revision + 1,
      status: YlPlaybackStatus.playing,
      timeline: YlTimeline(position: Duration(milliseconds: ms)),
      videoGeometry: const YlVideoGeometry(
        encodedSize: YlPixelSize(100, 100),
        displaySize: YlPixelSize(100, 100),
      ),
    ),
  );
  testWidgets(
    'PGS public session renders pixel geometry, recolors and clears lifecycle',
    (tester) async {
      final created = <ui.Image>[];
      final oldCreate = ui.Image.onCreate;
      ui.Image.onCreate = (i) {
        created.add(i);
        oldCreate?.call(i);
      };
      addTearDown(() => ui.Image.onCreate = oldCreate);
      await tester.runAsync(() => session.discoverEmbeddedSubtitles());
      expect(player.state.subtitles.tracks.map((t) => t.id), [
        'mkv:101',
        'mkv:102',
      ]);
      await session.selectSubtitleTrack('mkv:101');
      position(1000);
      final key = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 300,
                height: 200,
                child: YlPlayerView(controller: player),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(PgsSubtitleOverlay), findsNothing);
      backend.emitFirstFrame(id);
      position(1000);
      await tester.pump();
      Future<void> settle() async {
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
      }

      Future<void> checkPixels(List<int> color) async {
        await settle();
        final image = (await tester.runAsync(
          () =>
              (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
                  .toImage(),
        ))!;
        final data = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        for (var y = 60; y < 64; y++) {
          for (var x = 90; x < 98; x++) {
            final expected = y < 62 && x >= 94 ? [127, 0, 0] : color;
            expect(
              [
                for (var c = 0; c < 3; c++)
                  data.getUint8((y * 300 + x) * 4 + c),
              ],
              expected,
              reason: 'pixel$x,$y',
            );
          }
        }
        image.dispose();
      }

      expect(find.byType(PgsSubtitleOverlay), findsOneWidget);
      await checkPixels([255, 255, 255]);
      position(2000);
      await tester.pump();
      await checkPixels([0, 0, 0]);
      position(3000);
      await tester.pump();
      expect(find.byType(PgsSubtitleOverlay), findsNothing);
      position(1000);
      await tester.pump();
      await settle();
      await session.selectSubtitleTrack('mkv:102');
      await tester.pump();
      expect(find.byType(PgsSubtitleOverlay), findsNothing);
      expect(find.text('forced', findRichText: true), findsOneWidget);
      await session.selectSubtitleTrack('mkv:101');
      await tester.pump();
      expect(find.text('forced', findRichText: true), findsNothing);
      await session.setSubtitleOffset(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byType(PgsSubtitleOverlay), findsNothing);
      position(1600);
      await tester.pump();
      await settle();
      expect(find.byType(PgsSubtitleOverlay), findsOneWidget);
      await session.setSubtitleOffset(const Duration(milliseconds: -500));
      position(500);
      await tester.pump();
      expect(find.byType(PgsSubtitleOverlay), findsOneWidget);
      backend.delayCommand('seekTo', id);
      final seeking = session.seekTo(const Duration(seconds: 5));
      await tester.pump();
      expect(find.byType(PgsSubtitleOverlay), findsNothing);
      backend.completeCommand('seekTo', id);
      await seeking;
      position(500);
      await tester.pump();
      await settle();
      await session.selectSubtitleTrack(null);
      await tester.pump();
      expect(find.byType(PgsSubtitleOverlay), findsNothing);
      expect(created.every((i) => i.debugDisposed), true);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'network failure leaves playback and selected subtitle state unchanged',
    () async {
      await session.discoverEmbeddedSubtitles();
      await session.selectSubtitleTrack('mkv:101');
      position(1500);
      backend.emitFirstFrame(id);
      final old = player.state;
      server.handle = (q, n) {
        q.response.statusCode = 403;
        q.response.write('private server detail');
        unawaited(q.response.close());
      };
      await expectLater(
        session.discoverEmbeddedSubtitles(),
        throwsA(
          isA<YlPlayerException>()
              .having(
                (e) => e.failure.code,
                'code',
                YlFailureCodes.networkFailed,
              )
              .having((e) => e.toString(), 'safe', isNot(contains('private'))),
        ),
      );
      expect(player.state, old);
      expect(
        player.textSubtitleCues.single.cue.pgs!.bitmaps.single.rgba.take(4),
        [255, 255, 255, 255],
      );
    },
  );
  for (final action in ['replace', 'stop', 'dispose', 'external']) {
    test(
      'held range is cancelled by $action and cannot publish late',
      () async {
        final held = Completer<HttpRequest>();
        server.handle = (q, n) {
          held.complete(q);
        };
        final pending = session.discoverEmbeddedSubtitles();
        final rejected = expectLater(
          pending,
          throwsA(isA<YlPlayerException>()),
        );
        final q = await held.future;
        switch (action) {
          case 'replace':
            final next = player.load(const YlFileSource('/new.mp4'));
            backend.commit(const YlPlaybackSessionId('new'));
            await next;
          case 'stop':
            await player.stop();
          case 'dispose':
            await player.dispose();
          case 'external':
            await session.replaceExternalSubtitles([]);
        }
        await rejected;
        server.reply(q);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(player.state.subtitles.tracks, isEmpty);
        expect(player.textSubtitleCues, isEmpty);
      },
    );
  }
}
