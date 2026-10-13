import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/embedded_vobsub_fixture.dart';
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
    server = await RangeServer.start(embeddedVobSub(padding: 5000000));
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
  for (final format in [YlMediaFormat.automatic, YlMediaFormat.matroska]) {
    test(
      'network $format sniffs content, skips media, sends conditional range and renders',
      () async {
        final r = TextSubtitleRuntime();
        await r.discover(source(format: format));
        r.select('mkv:101');
        expect(
          r
              .cuesAt(const Duration(seconds: 1))
              .single
              .cue
              .pgs!
              .bitmaps
              .single
              .rgba
              .take(4),
          [255, 255, 255, 255],
        );
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
    'legal chunked206 Matroska VobSub discovery completes without Content-Length',
    () async {
      server.handle = (q, n) => server.reply(q, chunked: true);
      final r = TextSubtitleRuntime();
      await r.discover(source());
      expect(r.state.tracks.single.id, 'mkv:101');
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
    'cross-origin redirect strips credentials before Matroska VobSub range scan',
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
    test(
      '$kind response keeps prior selected Matroska VobSub catalog',
      () async {
        final r = TextSubtitleRuntime();
        await r.discover(source());
        r.select('mkv:101');
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
        expect(
          r
              .cuesAt(const Duration(seconds: 1))
              .single
              .cue
              .pgs!
              .bitmaps
              .single
              .rgba
              .take(4),
          [255, 255, 255, 255],
        );
      },
    );
  }
  test(
    'managed response-header timeout terminates Matroska VobSub discovery',
    () async {
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
    },
  );
  test(
    'explicit non-Matroska VobSub format rejects before HTTP request',
    () async {
      final r = TextSubtitleRuntime();
      await expectLater(
        r.discover(source(format: YlMediaFormat.mov)),
        failure(YlFailureCodes.subtitleUnsupported),
      );
      expect(server.requests, isEmpty);
    },
  );
}
