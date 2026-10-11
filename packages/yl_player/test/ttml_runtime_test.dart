import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'package:yl_player/yl_player.dart';
import 'support/fake_player_platform.dart';

const ttml = '''<?xml version="1.0" encoding="UTF-8"?>
<tt xmlns="http://www.w3.org/ns/ttml"
 xmlns:tts="http://www.w3.org/ns/ttml#styling">
 <head><styling><style xml:id="bold" tts:fontWeight="bold"/></styling>
 <layout><region xml:id="bottom" tts:origin="10% 60%" tts:extent="80% 30%"
 tts:displayAlign="after"/></layout></head>
 <body region="bottom"><div>
 <p begin="1s" end="2s" style="bold">one &amp; <span tts:fontStyle="italic">two</span></p>
 <p begin="1.5s" dur="1.5s">second<br/>line</p>
 </div></body></tt>''';
Matcher failure(String code) => throwsA(
  isA<YlPlayerException>()
      .having((e) => e.failure.code, 'code', code)
      .having((e) => e.failure.scope, 'scope', YlFailureScope.command)
      .having((e) => e.failure.retryable, 'retryable', false),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File file;
  HttpOverrides? saved;
  setUp(() async {
    saved = HttpOverrides.current;
    HttpOverrides.global = null;
    dir = await Directory.systemTemp.createTemp('yl-ttml-');
    file = await File('${dir.path}/owned.ttml').writeAsString(ttml);
  });
  tearDown(() async {
    HttpOverrides.global = saved;
    await dir.delete(recursive: true);
  });
  YlExternalSubtitle sub([YlMediaSource? source]) => YlExternalSubtitle(
    id: 'tt',
    format: YlSubtitleFormat.ttml,
    source: source ?? YlFileSource(file.path),
  );

  test(
    'TTML file commits styled overlapping cues with offset and off',
    () async {
      final runtime = TextSubtitleRuntime();
      await runtime.replace([sub()]);
      runtime.select('tt');
      final cues = runtime.cuesAt(const Duration(milliseconds: 1600));
      expect(cues.map((c) => c.text.toPlainText()), [
        'one & two',
        'second\nline',
      ]);
      expect(
        cues.first.text.children!.first.style!.fontWeight,
        FontWeight.bold,
      );
      runtime.offset(const Duration(milliseconds: 500));
      expect(runtime.cuesAt(const Duration(milliseconds: 1200)), isEmpty);
      expect(runtime.cuesAt(const Duration(milliseconds: 2100)), hasLength(2));
      runtime.select(null);
      expect(runtime.cuesAt(const Duration(milliseconds: 2100)), isEmpty);
    },
  );
  test(
    'TTML managed HTTP retries then commits; malformed keeps old catalog',
    () async {
      final runtime = TextSubtitleRuntime();
      var count = 0;
      var body = ttml;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) {
        if (++count == 1) {
          r.response.statusCode = 503;
        } else {
          r.response.write(body);
        }
        unawaited(r.response.close());
      });
      final remote = sub(
        YlNetworkSource(
          Uri.parse('http://127.0.0.1:${server.port}/sub'),
          networkPolicy: const YlNetworkPolicy.managed(
            maxRetries: 1,
            baseRetryDelay: Duration.zero,
          ),
        ),
      );
      await runtime.replace([remote]);
      expect(count, 2);
      runtime.select('tt');
      final state = runtime.state;
      body = '<tt xmlns="http://www.w3.org/ns/ttml">secret malformed';
      await expectLater(
        runtime.replace([remote]),
        failure(YlFailureCodes.subtitleMalformed),
      );
      expect(count, 3);
      expect(runtime.state, state);
      expect(runtime.cuesAt(const Duration(milliseconds: 1600)), hasLength(2));
    },
  );
  test(
    'new TTML replacement cancels held HTTP body and rejects late completion',
    () async {
      final runtime = TextSubtitleRuntime();
      await runtime.replace([sub()]);
      runtime.select('tt');
      final held = Completer<HttpRequest>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) {
        r.response.bufferOutput = false;
        r.response.write('<tt xmlns="http://www.w3.org/ns/ttml">');
        unawaited(r.response.flush().then((_) => held.complete(r)));
      });
      final pending = runtime.replace([
        sub(
          YlNetworkSource(
            Uri.parse('http://127.0.0.1:${server.port}/held'),
            networkPolicy: const YlNetworkPolicy.managed(),
          ),
        ),
      ]);
      final rejected = expectLater(
        pending,
        failure(YlFailureCodes.loadCancelled),
      );
      final request = await held.future;
      await file.writeAsString(ttml.replaceAll('second', 'replacement'));
      await runtime.replace([sub()]);
      await rejected;
      request.response.write('</tt>');
      await request.response.close().catchError((Object _) {});
      expect(
        runtime
            .cuesAt(const Duration(milliseconds: 1600))
            .last
            .text
            .toPlainText(),
        'replacement\nline',
      );
    },
  );
  test(
    'decoded TTML control-like text is never reparsed as SRT markup',
    () async {
      await file.writeAsString(
        ttml.replaceAll('one &amp;', r'&lt;b&gt; {\an8} &amp;'),
      );
      final runtime = TextSubtitleRuntime();
      await runtime.replace([sub()]);
      runtime.select('tt');
      expect(
        runtime
            .cuesAt(const Duration(milliseconds: 1600))
            .first
            .text
            .toPlainText(),
        r'<b> {\an8} & two',
      );
    },
  );
  test('malformed XML syntax cannot publish over a selected catalog', () async {
    final runtime = TextSubtitleRuntime();
    await runtime.replace([sub()]);
    runtime.select('tt');
    final before = runtime.state;
    for (final malformed in [
      'garbage$ttml',
      ttml.replaceFirst('<p begin="1s"', '<p xml:lang=en begin="1s"'),
    ]) {
      await file.writeAsString(malformed);
      await expectLater(
        runtime.replace([sub()]),
        failure(YlFailureCodes.subtitleMalformed),
      );
      expect(runtime.state, before);
      expect(
        runtime
            .cuesAt(const Duration(milliseconds: 1600))
            .first
            .text
            .toPlainText(),
        'one & two',
      );
    }
  });
  testWidgets('public TTML load renders and follows seek, off and source reset', (
    tester,
  ) async {
    final backend = FakePlatformPlayer();
    final player = await YlPlayerController.create(
      platform: FakePlayerPlatform(backend),
      enableTextSubtitles: true,
    );
    addTearDown(player.dispose);
    final pending = player.load(const YlFileSource('/owned.mp4'));
    const sid = YlPlaybackSessionId('ttml');
    backend.commit(sid);
    final session = await pending;
    await tester.runAsync(() => session.replaceExternalSubtitles([sub()]));
    await session.selectSubtitleTrack('tt');
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
    // First-frame gate is driven by the same backend event as existing runtime tests.
    backend.emitFirstFrame(sid);
    position(1600);
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
    expect(find.text('one & two', findRichText: true), findsOneWidget);
    await session.selectSubtitleTrack(null);
    await tester.pump();
    expect(find.text('one & two', findRichText: true), findsNothing);
    await session.selectSubtitleTrack('tt');
    await session.seekTo(Duration.zero);
    await tester.pump();
    expect(find.text('one & two', findRichText: true), findsNothing);
    position(1600);
    await tester.pump();
    expect(find.text('one & two', findRichText: true), findsOneWidget);
    final next = player.load(const YlFileSource('/next.mp4'));
    backend.commit(const YlPlaybackSessionId('next'));
    await next;
    await tester.pump();
    expect(find.text('one & two', findRichText: true), findsNothing);
  });
}
