import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/fmp4_fixture.dart';
import 'support/range_server.dart';
import 'support/fake_player_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpOverrides? previous;
  late RangeServer server;
  late FakePlatformPlayer backend;
  late YlPlayerController player;
  late YlPlaybackSession session;
  const id = YlPlaybackSessionId('network-hybrid-mp4');
  setUp(() async {
    previous = HttpOverrides.current;
    HttpOverrides.global = null;
    server = await RangeServer.start(
      fragmented(
        padding: 40000,
        tracks: [
          Mp4Track(
            id: 101,
            entry: stppEntry(),
            samples: [stppSample('<p begin="0s" end="1s">before</p>')],
          ),
          Mp4Track(
            id: 102,
            entry: wvttEntry(),
            samples: [vttCue('initial vtt')],
          ),
        ],
        fragments: [
          Fragment(
            tracks: [
              FragmentTrack(
                id: 101,
                time: 1000,
                samples: [
                  stppSample(
                    '<p begin="1s" end="2s" region="r" tts:fontWeight="bold">normal</p>',
                    head:
                        '<head><layout><region xml:id="r" tts:origin="10% 60%" tts:extent="80% 30%" tts:displayAlign="after"/></layout></head>',
                  ),
                ],
              ),
            ],
          ),
          Fragment(
            sequence: 2,
            padding: 40000,
            tracks: [
              FragmentTrack(id: 102, time: 1000, samples: [vttCue('webvtt')]),
            ],
          ),
        ],
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
        encodedSize: YlPixelSize(300, 200),
        displaySize: YlPixelSize(300, 200),
      ),
    ),
  );
  testWidgets(
    'network tracks select/render/off/offset/seek using current source metadata',
    (tester) async {
      await tester.runAsync(() => session.discoverEmbeddedSubtitles());
      expect(player.state.subtitles.tracks.map((t) => t.id), [
        'mp4:101',
        'mp4:102',
      ]);
      for (final q in server.requests) {
        expect(q.headers.value('authorization'), 'owned secret');
      }
      await session.selectSubtitleTrack('mp4:101');
      position(500);
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
      expect(find.text('before', findRichText: true), findsOneWidget);
      position(1500);
      await tester.pump();
      expect(find.text('before', findRichText: true), findsNothing);
      expect(find.text('normal', findRichText: true), findsOneWidget);
      final rich = tester.widget<RichText>(
        find.text('normal', findRichText: true),
      );
      final outer = rich.text as TextSpan;
      final span =
          ((outer.children!.single as TextSpan).children!.single as TextSpan);
      expect(span.style!.fontWeight, FontWeight.bold);
      final viewRect = tester.getRect(find.byType(YlPlayerView));
      final cueRect = tester.getRect(find.text('normal', findRichText: true));
      expect(cueRect.left, closeTo(viewRect.left + viewRect.width * .1, .01));
      expect(cueRect.width, closeTo(viewRect.width * .8, .01));
      expect(
        cueRect.bottom,
        closeTo(viewRect.center.dy + (viewRect.width * 2 / 3) * .4, .01),
      );
      expect(player.state.subtitles.tracks.first.format, YlSubtitleFormat.ttml);
      await session.selectSubtitleTrack('mp4:102');
      await tester.pump();
      expect(find.text('normal', findRichText: true), findsNothing);
      expect(find.text('webvtt', findRichText: true), findsOneWidget);
      await session.setSubtitleOffset(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('webvtt', findRichText: true), findsNothing);
      position(2500);
      await tester.pump();
      expect(find.text('webvtt', findRichText: true), findsOneWidget);
      backend.delayCommand('seekTo', id);
      final seeking = session.seekTo(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('webvtt', findRichText: true), findsNothing);
      backend.completeCommand('seekTo', id);
      await seeking;
      position(5000);
      await tester.pump();
      expect(find.text('webvtt', findRichText: true), findsNothing);
      await session.selectSubtitleTrack(null);
      expect(player.textSubtitleCues, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'network failure leaves playback and selected subtitle state unchanged',
    () async {
      await session.discoverEmbeddedSubtitles();
      await session.selectSubtitleTrack('mp4:101');
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
      expect(player.textSubtitleCues.single.text.toPlainText(), 'normal');
    },
  );
  for (final action in ['replace', 'stop', 'dispose', 'external']) {
    test(
      'held later fragment range is cancelled by $action and cannot publish late',
      () async {
        final held = Completer<HttpRequest>();
        server.handle = (q, n) {
          if (server.range(q).$1 >= 65536) {
            held.complete(q);
          } else {
            server.reply(q);
          }
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
