import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'package:yl_player/yl_player.dart';
import 'support/vobsub_fixture.dart';

Matcher failure(String code) => throwsA(
  isA<YlPlayerException>().having((e) => e.failure.code, 'code', code),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File sub, idx;
  HttpOverrides? saved;
  setUp(() async {
    saved = HttpOverrides.current;
    HttpOverrides.global = null;
    dir = await Directory.systemTemp.createTemp('yl-vobsub-');
    sub = await File('${dir.path}/owned.sub').writeAsBytes(vobSub());
    idx = await File('${dir.path}/owned.idx').writeAsBytes(vobIdx());
  });
  tearDown(() async {
    HttpOverrides.global = saved;
    await dir.delete(recursive: true);
  });
  YlExternalSubtitle source({YlMediaSource? binary, YlMediaSource? index}) =>
      YlExternalSubtitle(
        id: 'vob',
        format: YlSubtitleFormat.vobsub,
        source: binary ?? YlFileSource(sub.path),
        companionSource: index ?? YlFileSource(idx.path),
      );
  test('paired files render media-timed bitmap and offset/off', () async {
    final r = TextSubtitleRuntime();
    await r.replace([source()]);
    r.select('vob');
    expect(r.cuesAt(const Duration(milliseconds: 999)), isEmpty);
    final b = r
        .cuesAt(const Duration(seconds: 1))
        .single
        .cue
        .pgs!
        .bitmaps
        .single;
    expect([b.x, b.y, b.width, b.height], [20, 30, 4, 3]);
    expect(b.rgba.take(4), [255, 255, 255, 255]);
    expect(r.cuesAt(const Duration(milliseconds: 2024)), isEmpty);
    r.offset(const Duration(milliseconds: 500));
    expect(r.cuesAt(const Duration(milliseconds: 1400)), isEmpty);
    expect(r.cuesAt(const Duration(milliseconds: 1500)), hasLength(1));
    r.select(null);
    expect(r.cuesAt(const Duration(seconds: 2)), isEmpty);
  });
  test(
    'both managed resources load, binary retries, bad pair preserves catalog',
    () async {
      final calls = <String>[];
      var attempts = 0;
      var bad = false;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((q) {
        calls.add(q.uri.path);
        if (q.uri.path == '/idx') {
          q.response.add(bad ? [0, 1] : vobIdx());
        } else if (++attempts == 1) {
          q.response.statusCode = 503;
        } else {
          q.response.add(vobSub());
        }
        unawaited(q.response.close());
      });
      YlNetworkSource net(String path) => YlNetworkSource(
        Uri.parse('http://127.0.0.1:${server.port}/$path'),
        networkPolicy: const YlNetworkPolicy.managed(
          maxRetries: 1,
          baseRetryDelay: Duration.zero,
        ),
      );
      final r = TextSubtitleRuntime();
      final pair = source(binary: net('sub'), index: net('idx'));
      await r.replace([pair]);
      r.select('vob');
      final old = r.state;
      expect(calls, ['/idx', '/sub', '/sub']);
      bad = true;
      await expectLater(
        r.replace([pair]),
        failure(YlFailureCodes.subtitleMalformed),
      );
      expect(r.state, old);
      expect(r.cuesAt(const Duration(seconds: 1)), hasLength(1));
    },
  );
  for (final stage in ['idx', 'sub']) {
    test(
      'replacement cancels held $stage resource and ignores late completion',
      () async {
        final r = TextSubtitleRuntime();
        await r.replace([source()]);
        r.select('vob');
        final arrived = Completer<HttpRequest>();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((q) {
          final data = q.uri.path == '/idx' ? vobIdx() : vobSub();
          if (q.uri.path == '/$stage') {
            q.response.bufferOutput = false;
            q.response.add(data.take(1).toList());
            unawaited(q.response.flush().then((_) => arrived.complete(q)));
          } else {
            q.response.add(data);
            unawaited(q.response.close());
          }
        });
        YlNetworkSource net(String path) => YlNetworkSource(
          Uri.parse('http://127.0.0.1:${server.port}/$path'),
          networkPolicy: const YlNetworkPolicy.managed(),
        );
        final pending = r.replace([
          source(binary: net('sub'), index: net('idx')),
        ]);
        final rejected = expectLater(
          pending,
          failure(YlFailureCodes.loadCancelled),
        );
        final q = await arrived.future;
        await r.replace([source()]);
        await rejected;
        q.response.add(
          (stage == 'idx' ? vobIdx() : vobSub(spu: vobSpu(x: 40)))
              .skip(1)
              .toList(),
        );
        unawaited(q.response.close().catchError((Object _) {}));
        await Future<void>.delayed(Duration.zero);
        expect(
          r.cuesAt(const Duration(seconds: 1)).single.cue.pgs!.bitmaps.single.x,
          20,
        );
      },
    );
  }
  test('pair input sizes share the encoded catalog allowance', () async {
    final padding = '\n#${'x' * 2000}';
    await idx.writeAsString(
      '${vobIdxText()}${List.filled(800, padding).join()}',
    );
    await sub.writeAsBytes([
      ...vobSub(),
      for (var i = 0; i < 40; i++) ...[
        0,
        0,
        1,
        0xbe,
        255,
        255,
        ...List.filled(65535, 255),
      ],
    ]);
    expect(await idx.length(), lessThan(4 * 1024 * 1024));
    expect(await sub.length(), lessThan(4 * 1024 * 1024));
    final r = TextSubtitleRuntime();
    await expectLater(
      r.replace([source()]),
      failure(YlFailureCodes.subtitleTooLarge),
    );
    expect(r.state.tracks, isEmpty);
  });
  test('missing companion preserves current catalog', () async {
    final r = TextSubtitleRuntime();
    await r.replace([source()]);
    r.select('vob');
    final old = r.state;
    await expectLater(
      r.replace([
        YlExternalSubtitle(
          id: 'bad',
          format: YlSubtitleFormat.vobsub,
          source: YlFileSource(sub.path),
        ),
      ]),
      failure(YlFailureCodes.subtitleMalformed),
    );
    expect(r.state, old);
  });
  test('VobSub documents share preallocation RGBA catalog allowance', () async {
    final rows = [
      for (var row = 0; row < 1024; row++) ...[0, 1],
    ];
    final bigSub = await File('${dir.path}/large.sub').writeAsBytes(
      vobSub(
        spu: vobAnimated(
          initial: vobSpu(
            x: 0,
            y: 0,
            w: 2048,
            h: 2048,
            top: rows,
            bottom: rows,
            stop: false,
          ),
        ),
      ),
    );
    final bigIdx = await File(
      '${dir.path}/large.idx',
    ).writeAsString(vobIdxText(width: 2048, height: 2048));
    final r = TextSubtitleRuntime();
    await r.replace([source()]);
    r.select('vob');
    final old = r.state;
    // Each document is 32 MiB expanded; two fit exactly, the third must fail.
    await expectLater(
      r.replace([
        for (final id in ['one', 'two', 'three'])
          YlExternalSubtitle(
            id: id,
            format: YlSubtitleFormat.vobsub,
            source: YlFileSource(bigSub.path),
            companionSource: YlFileSource(bigIdx.path),
          ),
      ]),
      failure(YlFailureCodes.subtitleTooLarge),
    );
    expect(r.state, old);
    expect(r.cuesAt(const Duration(seconds: 1)), hasLength(1));
  });
}
