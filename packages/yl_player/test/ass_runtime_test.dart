import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'package:yl_player/yl_player.dart';

import 'support/ass_fixture.dart';

final ass = assFixture(
  extra: r'Dialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,second\Nline',
);
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
    dir = await Directory.systemTemp.createTemp('yl-ass-');
    file = await File('${dir.path}/owned.ass').writeAsString(ass);
  });
  tearDown(() async {
    HttpOverrides.global = saved;
    await dir.delete(recursive: true);
  });
  YlExternalSubtitle sub([YlMediaSource? source]) => YlExternalSubtitle(
    id: 'tt',
    format: YlSubtitleFormat.ass,
    source: source ?? YlFileSource(file.path),
  );

  test('catalog aggregate run overflow keeps the selected catalog', () async {
    final runtime = TextSubtitleRuntime();
    await runtime.replace([sub()]);
    runtime.select('tt');
    final state = runtime.state;
    final line =
        'Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,${List.filled(512, r'{\b1}a').join()}';
    await file.writeAsString(
      assFixture(text: 'a', extra: List.filled(20, line).join('\n')),
    );
    final second = await File('${dir.path}/second.ass').writeAsString(
      '${await file.readAsString()}\nDialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\p1}unsupported after budget',
    );
    await expectLater(
      runtime.replace([
        sub(),
        YlExternalSubtitle(
          id: 'second',
          format: YlSubtitleFormat.ass,
          source: YlFileSource(second.path),
        ),
      ]),
      failure(YlFailureCodes.subtitleTooLarge),
    );
    expect(runtime.state, state);
    expect(runtime.cuesAt(const Duration(milliseconds: 1600)), hasLength(2));
  });
  test(
    'ASS file commits styled overlapping cues with offset and off',
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
  test('SSA file uses the same catalog and renders decoded text', () async {
    await file.writeAsString(assFixture(ssa: true));
    final runtime = TextSubtitleRuntime();
    await runtime.replace([
      YlExternalSubtitle(
        id: 'ssa',
        format: YlSubtitleFormat.ssa,
        source: YlFileSource(file.path),
      ),
    ]);
    runtime.select('ssa');
    expect(
      runtime.cuesAt(const Duration(seconds: 2)).single.text.toPlainText(),
      'one & two',
    );
  });
  test(
    'ASS managed HTTP retries then commits; malformed keeps old catalog',
    () async {
      final runtime = TextSubtitleRuntime();
      var count = 0;
      var body = ass;
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
      body = 'secret malformed';
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
    'new ASS replacement cancels held HTTP body and rejects late completion',
    () async {
      final runtime = TextSubtitleRuntime();
      await runtime.replace([sub()]);
      runtime.select('tt');
      final held = Completer<HttpRequest>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) {
        r.response.bufferOutput = false;
        r.response.write('[Script Info]');
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
      await file.writeAsString(ass.replaceAll('second', 'replacement'));
      await runtime.replace([sub()]);
      await rejected;
      request.response.write('late');
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
}
