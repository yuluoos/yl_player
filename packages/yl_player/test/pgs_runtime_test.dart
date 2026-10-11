import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'package:yl_player/yl_player.dart';
import 'support/pgs_fixture.dart';

Matcher failure(String code) => throwsA(
  isA<YlPlayerException>()
      .having((e) => e.failure.code, 'code', code)
      .having((e) => e.failure.scope, 'scope', YlFailureScope.command),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File file;
  HttpOverrides? saved;
  setUp(() async {
    saved = HttpOverrides.current;
    HttpOverrides.global = null;
    dir = await Directory.systemTemp.createTemp('yl-pgs-');
    file = await File('${dir.path}/owned.sup').writeAsBytes(pgsFixture());
  });
  tearDown(() async {
    HttpOverrides.global = saved;
    await dir.delete(recursive: true);
  });
  YlExternalSubtitle sub([YlMediaSource? source]) => YlExternalSubtitle(
    id: 'pgs',
    format: YlSubtitleFormat.pgs,
    source: source ?? YlFileSource(file.path),
  );
  test(
    'binary SUP file loads, updates palette, clears and follows offsets',
    () async {
      final r = TextSubtitleRuntime();
      await r.replace([sub()]);
      r.select('pgs');
      expect(r.cuesAt(const Duration(milliseconds: 999)), isEmpty);
      expect(r.cuesAt(const Duration(seconds: 1)), hasLength(1));
      expect(r.cuesAt(const Duration(seconds: 2)), hasLength(1));
      expect(r.cuesAt(const Duration(seconds: 3)), isEmpty);
      r.offset(const Duration(milliseconds: 500));
      expect(r.cuesAt(const Duration(milliseconds: 1200)), isEmpty);
      expect(r.cuesAt(const Duration(milliseconds: 2100)), hasLength(1));
      r.select(null);
      expect(r.cuesAt(const Duration(seconds: 2)), isEmpty);
    },
  );
  test(
    'expanded bitmap budget is shared across external catalog documents',
    () async {
      // Three 2048-square frames = 48 MiB RGBA from a compact owned RLE object.
      // Each document fits alone; the second must receive only 16 MiB allowance.
      final rle = <int>[
        for (var row = 0; row < 2048; row++) ...[0, 0xc8, 0, 1, 0, 0],
      ];
      final large = await File('${dir.path}/large.sup').writeAsBytes([
        ...pgsPcs(width: 2048, height: 2048, objects: [pgsRef(x: 0, y: 0)]),
        ...pgsWindow(w: 2048, h: 2048),
        ...pgsPalette(),
        ...pgsObject(w: 2048, h: 2048, data: rle),
        ...pgsEnd(),
        for (final ticks in [180000, 270000]) ...[
          ...pgsPcs(
            pts: ticks,
            width: 2048,
            height: 2048,
            state: 0,
            update: true,
          ),
          ...pgsPalette(pts: ticks),
          ...pgsEnd(ticks),
        ],
      ]);
      final r = TextSubtitleRuntime();
      await r.replace([sub()]);
      r.select('pgs');
      final old = r.state;
      await expectLater(
        r.replace([
          for (final id in ['one', 'two'])
            YlExternalSubtitle(
              id: id,
              format: YlSubtitleFormat.pgs,
              source: YlFileSource(large.path),
            ),
        ]),
        failure(YlFailureCodes.subtitleTooLarge),
      );
      expect(r.state, old);
      expect(r.cuesAt(const Duration(seconds: 1)), hasLength(1));
    },
  );
  test(
    'managed binary HTTP retries and malformed replacement preserves catalog',
    () async {
      var count = 0;
      var body = pgsFixture();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((q) {
        if (++count == 1) {
          q.response.statusCode = 503;
        } else {
          q.response.add(body);
        }
        unawaited(q.response.close());
      });
      final remote = sub(
        YlNetworkSource(
          Uri.parse('http://127.0.0.1:${server.port}/owned.sup'),
          networkPolicy: const YlNetworkPolicy.managed(
            maxRetries: 1,
            baseRetryDelay: Duration.zero,
          ),
        ),
      );
      final r = TextSubtitleRuntime();
      await r.replace([remote]);
      expect(count, 2);
      r.select('pgs');
      final state = r.state;
      body = [0x50, 0x47, 0];
      await expectLater(
        r.replace([remote]),
        failure(YlFailureCodes.subtitleMalformed),
      );
      expect(r.state, state);
      expect(r.cuesAt(const Duration(seconds: 1)), hasLength(1));
    },
  );
  test(
    'replacement cancels held binary response and cannot publish late data',
    () async {
      final r = TextSubtitleRuntime();
      await r.replace([sub()]);
      r.select('pgs');
      final held = Completer<HttpRequest>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((q) {
        q.response.bufferOutput = false;
        q.response.add([0x50, 0x47]);
        unawaited(q.response.flush().then((_) => held.complete(q)));
      });
      final pending = r.replace([
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
      final q = await held.future;
      await r.replace([sub()]);
      await rejected;
      q.response.add(pgsFixture(paletteUpdate: false).skip(2).toList());
      // Client cancellation already completed above; a disconnected server's
      // write completion is not an observable subtitle contract.
      unawaited(q.response.close().catchError((Object _) {}));
      await Future<void>.delayed(Duration.zero);
      expect(
        r
            .cuesAt(const Duration(seconds: 2))
            .single
            .cue
            .pgs!
            .bitmaps
            .single
            .rgba[0],
        0,
      );
      expect(r.cuesAt(const Duration(seconds: 1)), hasLength(1));
    },
  );
}
