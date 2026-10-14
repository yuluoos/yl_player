import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';

void main() {
  test(
    'DASH discovery is lazy, selected windows advance and isolate later failures',
    () async {
      final requests = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) {
        requests.add(r.uri.path);
        if (r.uri.path == '/root.mpd') {
          r.response.write(
            '''<MPD mediaPresentationDuration="PT8S"><Period duration="PT8S"><AdaptationSet id="1" mimeType="text/vtt"><Representation id="sub"><SegmentTemplate duration="2" media="s-\$Number\$.vtt"/></Representation></AdaptationSet></Period></MPD>''',
          );
        } else if (r.uri.path == '/s-4.vtt') {
          r.response.write('damaged subtitle');
        } else {
          final n = int.parse(r.uri.path.split('-')[1].split('.')[0]);
          r.response.write(
            'WEBVTT\n\n00:00:0${(n - 1) * 2}.000 --> 00:00:0${n * 2}.000\nsegment $n\n',
          );
        }
        unawaited(r.response.close());
      });
      final runtime = TextSubtitleRuntime();
      addTearDown(runtime.reset);
      final changed = <int>[];
      final failure = Completer<YlPlayerException>();
      runtime.onChanged = () => changed.add(1);
      runtime.onFailure = (e) => failure.complete(e);
      await runtime.discover(
        YlNetworkSource(
          Uri.parse('http://127.0.0.1:${server.port}/root.mpd'),
          format: YlMediaFormat.dash,
        ),
      );
      expect(requests, ['/root.mpd']);
      expect(runtime.state.tracks, hasLength(1));
      await runtime.selectAt(runtime.state.tracks.single.id, Duration.zero);
      expect(requests, ['/root.mpd', '/s-1.vtt', '/s-2.vtt']);
      expect(
        runtime.cuesAt(const Duration(seconds: 1)).single.cue.payload,
        'segment 1',
      );
      await runtime.replace([]);
      expect(runtime.state.selectedTrackId, isNotNull);
      runtime.updatePosition(const Duration(seconds: 4));
      expect(
        (await failure.future.timeout(
          const Duration(seconds: 3),
        )).failure.scope,
        YlFailureScope.command,
      );
      expect(runtime.cuesAt(const Duration(seconds: 4)), isEmpty);
      expect(runtime.state.selectedTrackId, isNotNull);
      final count = requests.length;
      runtime.updatePosition(const Duration(milliseconds: 4500));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requests, hasLength(count));
      runtime.select(null);
      expect(runtime.cuesAt(Duration.zero), isEmpty);
    },
  );
  for (final operation in ['off', 'reset', 'seek']) {
    test('late DASH response cannot publish after $operation', () async {
      final seen = Completer<HttpRequest>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) {
        if (r.uri.path == '/root.mpd') {
          r.response.write(
            '<MPD mediaPresentationDuration="PT2S"><Period duration="PT2S"><AdaptationSet mimeType="text/vtt"><Representation id="t"><BaseURL>held.vtt</BaseURL></Representation></AdaptationSet></Period></MPD>',
          );
          unawaited(r.response.close());
        } else {
          seen.complete(r);
        }
      });
      final runtime = TextSubtitleRuntime();
      addTearDown(runtime.reset);
      var changes = 0, errors = 0;
      runtime.onChanged = () => changes++;
      runtime.onFailure = (_) => errors++;
      await runtime.discover(
        YlNetworkSource(Uri.parse('http://127.0.0.1:${server.port}/root.mpd')),
      );
      final selected = runtime.selectAt(
        runtime.state.tracks.single.id,
        Duration.zero,
      );
      final rejection = expectLater(
        selected,
        throwsA(isA<YlPlayerException>()),
      );
      final held = await seen.future;
      switch (operation) {
        case 'off':
          runtime.select(null);
        case 'reset':
          runtime.reset();
        case 'seek':
          runtime.suspendWindow();
      }
      held.response.write('WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nstale\n');
      await held.response.close().catchError((Object _) {});
      await rejection;
      expect(runtime.cuesAt(const Duration(seconds: 1)), isEmpty);
      expect(changes, 0);
      expect(errors, 0);
    });
  }

  test(
    'catalog publication cancels a selection started during rediscovery',
    () async {
      final rootAgain = Completer<HttpRequest>(),
          oldSegment = Completer<HttpRequest>();
      var roots = 0, changes = 0;
      String manifest(String file) =>
          '<MPD mediaPresentationDuration="PT2S"><Period duration="PT2S"><AdaptationSet mimeType="text/vtt"><Representation id="t"><BaseURL>$file</BaseURL></Representation></AdaptationSet></Period></MPD>';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) {
        if (r.uri.path == '/root.mpd') {
          if (++roots == 1) {
            r.response.write(manifest('old.vtt'));
            unawaited(r.response.close());
          } else {
            rootAgain.complete(r);
          }
        } else {
          oldSegment.complete(r);
        }
      });
      final runtime = TextSubtitleRuntime();
      addTearDown(runtime.reset);
      runtime.onChanged = () => changes++;
      final source = YlNetworkSource(
        Uri.parse('http://127.0.0.1:${server.port}/root.mpd'),
      );
      await runtime.discover(source);
      final discovery = runtime.discover(source);
      final root = await rootAgain.future;
      final selection = runtime.selectAt(
        runtime.state.tracks.single.id,
        Duration.zero,
      );
      final rejected = expectLater(
        selection,
        throwsA(isA<YlPlayerException>()),
      );
      final old = await oldSegment.future;
      root.response.write(manifest('new.vtt'));
      await root.response.close();
      await discovery;
      old.response.write('WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nstale\n');
      await old.response.close().catchError((Object _) {});
      await rejected;
      expect(runtime.cuesAt(const Duration(seconds: 1)), isEmpty);
      expect(changes, 0);
    },
  );
  test('failed DASH selection retains the previously accepted track', () async {
    final dir = await Directory.systemTemp.createTemp('yl-dash-selection-');
    addTearDown(() => dir.delete(recursive: true));
    final file = await File('${dir.path}/root.mpd').writeAsString(
      '<MPD mediaPresentationDuration="PT2S"><Period duration="PT2S"><AdaptationSet id="1" mimeType="text/vtt"><Representation id="good"><BaseURL>good.vtt</BaseURL></Representation></AdaptationSet><AdaptationSet id="2" mimeType="text/vtt"><Representation id="bad"><BaseURL>bad.vtt</BaseURL></Representation></AdaptationSet></Period></MPD>',
    );
    await File(
      '${dir.path}/good.vtt',
    ).writeAsString('WEBVTT\n\n00:00:00.000 --> 00:00:02.000\naccepted\n');
    await File('${dir.path}/bad.vtt').writeAsString('damaged');
    final runtime = TextSubtitleRuntime();
    addTearDown(runtime.reset);
    await runtime.discover(YlFileSource(file.path));
    final good = runtime.state.tracks.first.id;
    await runtime.selectAt(good, Duration.zero);
    await expectLater(
      runtime.selectAt(runtime.state.tracks.last.id, Duration.zero),
      throwsA(isA<YlPlayerException>()),
    );
    expect(runtime.state.selectedTrackId, good);
    expect(
      runtime.cuesAt(const Duration(seconds: 1)).single.cue.payload,
      'accepted',
    );
  });
  test(
    'DASH and external choices share the 128-track published catalog limit',
    () async {
      final dir = await Directory.systemTemp.createTemp('yl-dash-catalog-');
      addTearDown(() => dir.delete(recursive: true));
      final root = await File('${dir.path}/root.mpd').writeAsString(
        '<MPD mediaPresentationDuration="PT4S">${List.generate(4, (p) => '<Period duration="PT1S">${List.generate(32, (i) => '<AdaptationSet id="${p * 32 + i}" mimeType="text/vtt"><Representation id="s"><BaseURL>sub.vtt</BaseURL></Representation></AdaptationSet>').join()}</Period>').join()}</MPD>',
      );
      final file = await File('${dir.path}/sub.vtt').writeAsString('WEBVTT\n');
      final external = YlExternalSubtitle(
        id: 'external',
        source: YlFileSource(file.path),
        format: YlSubtitleFormat.webvtt,
      );
      final runtime = TextSubtitleRuntime();
      addTearDown(runtime.reset);
      await runtime.replace([external]);
      await expectLater(
        runtime.discover(YlFileSource(root.path)),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.subtitleTooLarge,
          ),
        ),
      );
      expect(runtime.state.tracks.single.id, 'external');
      await runtime.replace([]);
      await runtime.discover(YlFileSource(root.path));
      expect(runtime.state.tracks, hasLength(128));
      await expectLater(
        runtime.replace([external]),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.subtitleTooLarge,
          ),
        ),
      );
      expect(runtime.state.tracks, hasLength(128));
    },
  );
}
