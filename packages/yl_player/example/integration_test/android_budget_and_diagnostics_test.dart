import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/ass_overlay.dart';

import '../../test/support/pgs_fixture.dart';
import '../../test/support/ass_fixture.dart';
import 'support/android_frame_observation.dart';
import 'support/apple_strict_support.dart';
import 'support/gated_android_media_server.dart';
import 'support/range_media_server.dart';

const asset = 'assets/test_media/network_seek_h264_aac.mkv';
const probe = MethodChannel('yl_player_example/debug/frame_observation');

YlNetworkSource media(Uri uri) => YlNetworkSource(
  uri,
  format: YlMediaFormat.matroska,
  networkPolicy: strictNetwork,
);

Future<Map<String, int>> sample(
  String id,
  String phase, {
  bool candidate = false,
}) async {
  final observer = AndroidFrameObservation();
  final attached = candidate
      ? await observer.install(id)
      : await observer.installActive(id);
  try {
    final values = (await probe.invokeMapMethod<String, int>('bufferBudget'))!;
    debugPrint(
      'YL_BUDGET phase=$phase owner=${attached['sessionId']} values=${jsonEncode(values)}',
    );
    expect(values['targetBytes'], greaterThan(0));
    expect(
      values['allocatedBytes'],
      inInclusiveRange(0, values['targetBytes']!),
    );
    return values;
  } finally {
    await observer.remove();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('current and held candidate have observable allocator budgets', (
    tester,
  ) async {
    final first = await RangeMediaServer.start(asset: asset);
    final next = await GatedAndroidMediaServer.start();
    addTearDown(first.close);
    addTearDown(next.close);
    final player = await appleController(tester);
    final old = await player.load(media(first.mediaUri));
    await readyAndPlay(player, old);
    expect(
      (await sample(old.id.value, 'initial'))['allocatedBytes'],
      greaterThan(0),
    );
    await expectLater(
      player.load(
        media(next.uri),
        options: const YlLoadOptions(bufferStrategy: strictBuffer),
      ),
      failureCode(YlFailureCodes.policyUnsupported),
    );
    expect(next.requested.isCompleted, isFalse);
    expect(player.state.sessionId, old.id);
    final loading = player.load(media(next.uri));
    unawaited(loading.then<void>((_) {}, onError: (Object _) {}));
    await next.requested.future.timeout(const Duration(seconds: 10));
    await sample(old.id.value, 'currentDuringLoad');
    await sample(old.id.value, 'beforePrefix', candidate: true);
    next.prefix.complete();
    await next.deliveredPrefix.future.timeout(const Duration(seconds: 10));
    Map<String, int> observed;
    final deadline = Stopwatch()..start();
    do {
      observed = await sample(old.id.value, 'candidatePrefix', candidate: true);
      if (observed['allocatedBytes']! > 0) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } while (deadline.elapsed < const Duration(seconds: 5));
    expect(observed['allocatedBytes'], greaterThan(0));
    expect(player.state.sessionId, old.id);
    next.remainder.complete();
    final winner = await loading;
    await readyAndPlay(player, winner);
    await expectLater(old.play(), failureCode(YlFailureCodes.sessionStale));
    expect(
      (await sample(winner.id.value, 'committed'))['allocatedBytes'],
      greaterThan(0),
    );
    await player.stop();
    expect(player.state.status, YlPlaybackStatus.idle);
  });

  testWidgets('interrupted HTTP body resumes at the delivered byte and seeks', (
    tester,
  ) async {
    const cut = 262144;
    const validator = '"owned-v1"';
    final source = await RangeMediaServer.start(
      asset: asset,
      etag: validator,
      // The extractor reads the header and trailer cues, then reopens the media.
      scriptedResponses: const [
        RangeMediaResponse.automatic(),
        RangeMediaResponse.automatic(),
        RangeMediaResponse.truncated(cut),
      ],
    );
    addTearDown(source.close);
    final player = await appleController(tester);
    final session = await player.load(media(source.mediaUri));
    await readyAndPlay(player, session);
    final interrupted = source.requests.singleWhere(
      (r) => r.truncatedAt != null,
    );
    final offset = interrupted.truncatedAt!;
    final expectedRange = 'bytes=$offset-${source.lengthInBytes - 1}';
    final resumed = source.requests.where(
      (r) => r.header('range') == expectedRange,
    );
    final deadline = Stopwatch()..start();
    while (resumed.isEmpty && deadline.elapsed < const Duration(seconds: 8)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    debugPrint(
      'YL_RANGE cut=$offset requests=${jsonEncode(source.requests.map((r) => [r.header("range"), r.statusCode, r.truncatedAt]).toList())}',
    );
    expect(resumed, hasLength(1));
    expect(
      source.requests.indexOf(resumed.single),
      source.requests.indexOf(interrupted) + 1,
    );
    expect(resumed.single.header('if-range'), validator);
    expect(resumed.single.statusCode, HttpStatus.partialContent);
    await sample(session.id.value, 'reconnected');
    await session.seekTo(const Duration(seconds: 14));
    await stateWhere(
      player,
      (s) => s.timeline.position > const Duration(milliseconds: 14500),
    );
    await sample(session.id.value, 'afterSeek');
    expect(player.state.sessionId, session.id);
    expect(player.state.failure, isNull);
    debugPrint(
      'YL_RESUME total=${source.requests.length} resumes=${resumed.length} offset=$offset afterSeekMs=${player.state.timeline.position.inMilliseconds}',
    );
    await player.stop();
  });

  testWidgets(
    '403 redacts source and credentials without retrying, then recovers',
    (tester) async {
      final source = await RangeMediaServer.start(
        asset: asset,
        scriptedResponses: const [RangeMediaResponse.status(403)],
      );
      addTearDown(source.close);
      final player = await appleController(tester);
      const markers = [
        'owned-private-path',
        'owned-query-value',
        'owned-header-value',
        'owned-auth-value',
      ];
      final rejected = YlNetworkSource(
        source.mediaUri.replace(
          path: '/${markers[0]}',
          queryParameters: {'token': markers[1]},
        ),
        format: YlMediaFormat.matroska,
        networkPolicy: strictNetwork,
        request: YlHttpRequest(
          headers: {'X-Trace': markers[2]},
          credentials: {'Authorization': 'Bearer ${markers[3]}'},
        ),
      );
      try {
        await player.load(rejected);
        fail('A forbidden source must be rejected');
      } on YlPlayerException catch (e) {
        final f = e.failure;
        expect(f.code, YlFailureCodes.networkHttpForbidden);
        expect(f.retryable, isFalse);
        expect(f.diagnosticId, isNotEmpty);
        for (final marker in [...markers, '127.0.0.1']) {
          expect(
            [f.message, f.diagnosticId, f.toString(), e.toString()].join(' '),
            isNot(contains(marker)),
          );
        }
        debugPrint(
          'YL_DIAG code=${f.code} category=${f.category.name} retryable=${f.retryable} checked=${markers.length}',
        );
      }
      expect(source.requests, hasLength(1));
      expect(
        source.requests.single.header('authorization'),
        'Bearer ${markers[3]}',
      );
      expect(player.state.sessionId, isNull);
      final recovered = await player.load(media(source.mediaUri));
      await readyAndPlay(player, recovered);
      await player.stop();
    },
  );

  testWidgets('oversized PGS canvas leaves the current video advancing', (
    tester,
  ) async {
    final source = await RangeMediaServer.start(asset: asset);
    addTearDown(source.close);
    final dir = await Directory.systemTemp.createTemp('owned-pgs-');
    addTearDown(() => dir.delete(recursive: true));
    final sup = await File(
      '${dir.path}/canvas.sup',
    ).writeAsBytes([...pgsPcs(width: 8193), ...pgsEnd()]);
    final player = await YlPlayerController.create(enableTextSubtitles: true);
    addTearDown(player.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: YlPlayerView(controller: player),
      ),
    );
    final session = await player.load(media(source.mediaUri));
    await readyAndPlay(player, session);
    await expectLater(
      session.replaceExternalSubtitles([
        YlExternalSubtitle(
          id: 'oversized',
          source: YlFileSource(sup.path),
          format: YlSubtitleFormat.pgs,
        ),
      ]),
      failureCode(YlFailureCodes.subtitleTooLarge),
    );
    final before = player.state.timeline.position;
    await stateWhere(
      player,
      (s) =>
          s.status == YlPlaybackStatus.playing &&
          s.timeline.position > before + const Duration(milliseconds: 500),
    );
    expect(player.state.sessionId, session.id);
    expect(player.state.failure, isNull);
    expect(player.state.subtitles.tracks, isEmpty);
    await player.stop();
  });

  testWidgets(
    'unavailable ASS font renders fallback glyphs and video continues',
    (tester) async {
      final mediaServer = await RangeMediaServer.start(asset: asset);
      addTearDown(mediaServer.close);
      final dir = await Directory.systemTemp.createTemp('owned-ass-');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File('${dir.path}/missing-font.ass').writeAsString(
        assFixture(
          text: 'Fallback',
        ).replaceFirst('Default,Ahem,', 'Default,OwnedAbsentTypeface4091,'),
      );
      final player = await YlPlayerController.create(enableTextSubtitles: true);
      addTearDown(player.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: YlPlayerView(controller: player),
        ),
      );
      final session = await player.load(media(mediaServer.mediaUri));
      await readyAndPlay(player, session);
      await session.pause();
      await session.replaceExternalSubtitles([
        YlExternalSubtitle(
          id: 'missing-font',
          format: YlSubtitleFormat.ass,
          source: YlFileSource(file.path),
        ),
      ]);
      await session.selectSubtitleTrack('missing-font');
      await session.seekTo(const Duration(milliseconds: 1500));
      final overlay = find.byType(AssSubtitleOverlay);
      final deadline = Stopwatch()..start();
      while (overlay.evaluate().isEmpty &&
          deadline.elapsed < const Duration(seconds: 5)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(overlay, findsOneWidget);
      final paint = tester.widget<CustomPaint>(
        find.descendant(of: overlay, matching: find.byType(CustomPaint)),
      );
      final recorder = ui.PictureRecorder();
      paint.painter!.paint(ui.Canvas(recorder), const Size(300, 200));
      final picture = recorder.endRecording();
      final image = await picture.toImage(300, 200);
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        var red = 0;
        for (var i = 0; i < bytes.lengthInBytes; i += 4) {
          if (bytes.getUint8(i) > 127 &&
              bytes.getUint8(i + 1) < 64 &&
              bytes.getUint8(i + 2) < 64 &&
              bytes.getUint8(i + 3) > 127) {
            red++;
          }
        }
        expect(red, greaterThan(0));
        debugPrint('YL_FONT fallbackRedPixels=$red');
      } finally {
        image.dispose();
        picture.dispose();
      }
      await session.play();
      await stateWhere(
        player,
        (s) => s.timeline.position > const Duration(seconds: 2),
      );
      expect(player.state.sessionId, session.id);
      expect(player.state.failure, isNull);
      await player.stop();
    },
  );
}
