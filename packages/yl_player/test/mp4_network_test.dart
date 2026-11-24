import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/mp4_fixture.dart';
import 'support/range_server.dart';

Matcher failure(String code) => throwsA(
  isA<YlPlayerException>().having((e) => e.failure.code, 'code', code),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpOverrides? old;
  late RangeServer server;
  setUp(() async {
    old = HttpOverrides.current;
    HttpOverrides.global = null;
    server = await RangeServer.start(mp4(padding: 5000000));
  });
  tearDown(() async {
    await server.close();
    HttpOverrides.global = old;
  });
  YlNetworkSource source({
    YlNetworkPolicy policy = const YlNetworkPolicy.managed(maxRetries: 0),
    YlMediaFormat format = YlMediaFormat.automatic,
  }) => YlNetworkSource(
    server.uri,
    format: format,
    networkPolicy: policy,
    request: YlHttpRequest(credentials: {'Authorization': 'owned'}),
  );
  test(
    'many timed-text tracks publish a catalog before loading the selected window',
    () async {
      final movie = mp4(
        tracks: [
          for (var id = 1; id <= 41; id++)
            Mp4Track(
              id: id,
              samples: [textSample('first $id'), textSample('later $id')],
              durations: [60000, 1000],
            ),
        ],
        padding: 5000000,
      );
      final origin = await RangeServer.start(movie);
      addTearDown(origin.close);
      final runtime = TextSubtitleRuntime();
      addTearDown(runtime.reset);
      await runtime.discover(YlNetworkSource(origin.uri));
      expect(runtime.state.tracks, hasLength(41));
      final requests = origin.requests.length;
      await runtime.selectAt('mp4:41', const Duration(seconds: 60));
      expect(origin.requests.length, greaterThan(requests));
      expect(
        runtime.cuesAt(const Duration(seconds: 60)).single.text.toPlainText(),
        'later 41',
      );
      await runtime.selectAt('mp4:3', Duration.zero);
      expect(
        runtime.cuesAt(Duration.zero).single.text.toPlainText(),
        'first 3',
      );
      origin.handle = (q, _) => origin.reply(q, etag: '"another-version"');
      await expectLater(
        runtime.selectAt('mp4:25', Duration.zero),
        throwsA(isA<YlPlayerException>()),
      );
      expect(runtime.state.selectedTrackId, 'mp4:3');
      await runtime.selectAt(null, Duration.zero);
      expect(runtime.cuesAt(Duration.zero), isEmpty);
    },
  );
  test('12 languages with 850 cues each stay selectable', () async {
    final origin = await RangeServer.start(
      mp4(
        tracks: [
          for (var id = 1; id <= 12; id++)
            Mp4Track(
              id: id,
              samples: List.filled(850, textSample('language $id')),
              durations: List.filled(850, 1000),
            ),
        ],
      ),
    );
    addTearDown(origin.close);
    final runtime = TextSubtitleRuntime();
    addTearDown(runtime.reset);
    await runtime.discover(YlNetworkSource(origin.uri));
    expect(runtime.state.tracks, hasLength(12));
    const at = Duration(seconds: 600);
    await runtime.selectAt('mp4:12', at);
    expect(runtime.cuesAt(at).single.text.toPlainText(), 'language 12');
  });

  test(
    'a slow embedded window publishes its lookahead before catching up',
    () async {
      final origin = await RangeServer.start(
        mp4(
          tracks: [
            for (var id = 1; id <= 33; id++)
              Mp4Track(
                id: id,
                samples: [for (var i = 0; i < 32; i++) textSample('cue $i')],
                durations: List.filled(32, 1000),
              ),
          ],
        ),
      );
      addTearDown(origin.close);
      final runtime = TextSubtitleRuntime();
      addTearDown(runtime.reset);
      await runtime.discover(YlNetworkSource(origin.uri));
      await runtime.selectAt('mp4:1', Duration.zero);
      final firstRead = Completer<HttpRequest>();
      origin.handle = (q, _) {
        if (!firstRead.isCompleted) {
          firstRead.complete(q);
        } else {
          origin.reply(q);
        }
      };
      final publications = <bool>[];
      final caughtUp = Completer<void>();
      runtime.onChanged = () {
        publications.add(runtime.cuesAt(const Duration(seconds: 8)).isNotEmpty);
        if (runtime.cuesAt(const Duration(seconds: 25)).isNotEmpty &&
            !caughtUp.isCompleted) {
          caughtUp.complete();
        }
      };
      runtime.updatePosition(const Duration(seconds: 8));
      final held = await firstRead.future;
      runtime.updatePosition(const Duration(seconds: 16));
      origin.reply(held);
      await caughtUp.future.timeout(const Duration(seconds: 5));
      expect(publications, [true, false]);
      expect(
        runtime.cuesAt(const Duration(seconds: 16)).single.text.toPlainText(),
        'cue 16',
      );
    },
  );

  for (final format in [YlMediaFormat.automatic, YlMediaFormat.mp4]) {
    test(
      'network $format sniffs content, skips media, sends conditional range and renders',
      () async {
        final r = TextSubtitleRuntime();
        await r.discover(source(format: format));
        r.select('mp4:1');
        expect(r.cuesAt(Duration.zero).single.text.toPlainText(), 'hello');
        expect(server.sent, lessThan(50000));
        expect(server.requests.length, lessThan(5));
        expect(
          server.requests
              .skip(1)
              .every((q) => q.headers.value('if-match') == '"owned-v1"'),
          true,
        );
      },
    );
  }
  test(
    'legal chunked206 MP4 discovery completes without Content-Length',
    () async {
      server.handle = (q, n) => server.reply(q, chunked: true);
      final r = TextSubtitleRuntime();
      await r.discover(source());
      expect(r.state.tracks.single.id, 'mp4:1');
    },
  );
  test(
    'managed retries later range with credential and shared scan ledger',
    () async {
      server.handle = (q, n) {
        if (n == 2) {
          q.response.statusCode = 503;
          unawaited(q.response.close());
        } else {
          server.reply(q);
        }
      };
      final r = TextSubtitleRuntime();
      await r.discover(
        source(policy: const YlNetworkPolicy.managed(maxRetries: 1)),
      );
      expect(r.state.tracks.length, 1);
      expect(server.requests.length, 3);
      expect(
        server.requests.every(
          (q) => q.headers.value('authorization') == 'owned',
        ),
        true,
      );
      expect(
        server.requests[1].headers.value('range'),
        server.requests[2].headers.value('range'),
      );
    },
  );
  test(
    'cross-origin redirect strips credentials before MP4 range scan',
    () async {
      final target = await RangeServer.start(server.bytes);
      addTearDown(target.close);
      server.handle = (q, n) {
        q.response.statusCode = 302;
        q.response.headers.set('location', target.uri.toString());
        unawaited(q.response.close());
      };
      final r = TextSubtitleRuntime();
      await r.discover(
        source(
          policy: const YlNetworkPolicy.managed(maxRedirects: 1, maxRetries: 0),
        ),
      );
      expect(r.state.tracks.length, 1);
      expect(server.requests.length, 1);
      expect(
        target.requests.every((q) => q.headers.value('authorization') == null),
        true,
      );
    },
  );
  for (final kind in ['etag', '200', '403', 'malformed']) {
    test('$kind response keeps prior selected MP4 catalog', () async {
      final r = TextSubtitleRuntime();
      await r.discover(source());
      r.select('mp4:1');
      final before = r.state;
      var i = 0;
      server.handle = (q, n) {
        i++;
        if (kind == 'etag') {
          server.reply(q, etag: i == 1 ? '"v2"' : '"v3"');
        } else if (kind == 'malformed') {
          server.reply(
            q,
            body: List.filled(
              server.range(q).$2.clamp(0, server.bytes.length - 1) -
                  server.range(q).$1 +
                  1,
              0,
            ),
          );
        } else {
          q.response.statusCode = int.parse(kind);
          unawaited(q.response.close());
        }
      };
      await expectLater(
        r.discover(source()),
        throwsA(isA<YlPlayerException>()),
      );
      expect(r.state, before);
      expect(r.cuesAt(Duration.zero).single.text.toPlainText(), 'hello');
    });
  }
  test('managed response-header timeout terminates MP4 discovery', () async {
    server.handle = (q, n) {};
    final r = TextSubtitleRuntime();
    await expectLater(
      r.discover(
        source(
          policy: const YlNetworkPolicy.managed(
            maxRetries: 0,
            connectTimeout: Duration(milliseconds: 50),
          ),
        ),
      ),
      failure(YlFailureCodes.networkFailed),
    );
    expect(server.requests.length, 1);
  });
  test('explicit non-MP4 format rejects before HTTP request', () async {
    final r = TextSubtitleRuntime();
    await expectLater(
      r.discover(source(format: YlMediaFormat.mov)),
      failure(YlFailureCodes.subtitleUnsupported),
    );
    expect(server.requests, isEmpty);
  });
}
