import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'support/fake_player_platform.dart';
import 'support/vobsub_fixture.dart';
import 'support/pgs_fixture.dart';

const sid = YlPlaybackSessionId('text');
const sample =
    '1\n00:00:01,000 --> 00:00:02,000\n<b>one</b> &amp; two\n\n'
    '2\n00:00:01,500 --> 00:00:03,000\nsecond\n';

Matcher failure(String code) => throwsA(
  isA<YlPlayerException>()
      .having((e) => e.failure.code, 'code', code)
      .having((e) => e.failure.scope, 'scope', YlFailureScope.command)
      .having((e) => e.failure.retryable, 'retryable', false),
);

class ProtectedBackend extends FakePlatformPlayer
    implements YlPlatformProtectedVideoSurfaceProvider {
  @override
  YlProtectedVideoSurface? get protectedVideoSurface =>
      const YlProtectedVideoSurface(
        playerId: 1,
        surfaceId: 1,
        sessionId: 'text',
        generation: 1,
        viewType: 'owned/protected',
        platform: TargetPlatform.android,
      );
  @override
  Future<void> attachProtectedView(
    YlProtectedVideoSurface surface,
    int id,
  ) async {}
  @override
  Future<void> detachProtectedView(
    YlProtectedVideoSurface surface,
    int id,
  ) async {}
}

class NativeSubtitleBackend extends FakePlatformPlayer
    implements YlSubtitlePlatformPlayer {
  @override
  Future<void> replaceExternalSubtitles(
    YlPlaybackSessionId id,
    List<YlExternalSubtitle> sources,
  ) async {}
  @override
  Future<void> selectSubtitleTrack(
    YlPlaybackSessionId id,
    String? track,
  ) async {}
  @override
  Future<void> setSubtitleOffset(
    YlPlaybackSessionId id,
    Duration offset,
  ) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File file;
  late File unsupportedIndex;
  late FakePlatformPlayer backend;
  late YlPlayerController player;
  late YlPlaybackSession session;
  HttpOverrides? savedHttpOverrides;
  YlExternalSubtitle sub({String id = 'en', YlMediaSource? source}) =>
      YlExternalSubtitle(
        id: id,
        source: source ?? YlFileSource(file.path),
        format: YlSubtitleFormat.srt,
      );
  void position(
    int milliseconds, {
    YlPlaybackStatus status = YlPlaybackStatus.playing,
  }) {
    backend.emitState(
      backend.state.copyWith(
        revision: backend.state.revision + 1,
        status: status,
        timeline: YlTimeline(position: Duration(milliseconds: milliseconds)),
        videoGeometry: const YlVideoGeometry(
          encodedSize: YlPixelSize(1920, 1080),
          displaySize: YlPixelSize(1920, 1080),
        ),
      ),
    );
  }

  setUp(() async {
    savedHttpOverrides = HttpOverrides.current;
    HttpOverrides.global =
        null; // Owned loopback I/O, not Flutter's HTTP 400 fake.
    dir = await Directory.systemTemp.createTemp('yl-subtitles-');
    file = await File('${dir.path}/owned.srt').writeAsString(sample);
    unsupportedIndex = await File(
      '${dir.path}/unsupported.idx',
    ).writeAsString(vobIdxText(settings: 'custom colors: ON'));
    backend = FakePlatformPlayer();
    player = await YlPlayerController.create(
      platform: FakePlayerPlatform(backend),
      enableTextSubtitles: true,
    );
    final pending = player.load(const YlFileSource('/owned-video.mp4'));
    backend.commit(sid);
    session = await pending;
  });
  tearDown(() async {
    await player.dispose();
    await dir.delete(recursive: true);
    HttpOverrides.global = savedHttpOverrides;
  });

  for (final change in [
    'none',
    'tick',
    'seek',
    'off',
    'reselect',
    'offset',
    'replace',
    'new session',
    'stop',
    'dispose',
    'expired',
  ]) {
    test('bitmap resource failure ownership after $change', () async {
      await file.writeAsBytes(pgsFixture());
      final bitmap = YlExternalSubtitle(
        id: 'bitmap',
        source: YlFileSource(file.path),
        format: YlSubtitleFormat.pgs,
      );
      await session.replaceExternalSubtitles([bitmap]);
      await session.selectSubtitleTrack('bitmap');
      position(1000);
      backend.emitFirstFrame(sid);
      final cue = player.textSubtitleCues.single;
      final failures = <YlPlaybackFailedEvent>[];
      final events = player.events
          .where((e) => e is YlPlaybackFailedEvent)
          .cast<YlPlaybackFailedEvent>()
          .listen(failures.add);
      addTearDown(events.cancel);
      switch (change) {
        case 'tick':
          position(1100);
        case 'seek':
          await session.seekTo(const Duration(seconds: 1));
          position(1000);
        case 'off':
          await session.selectSubtitleTrack(null);
        case 'reselect':
          await session.selectSubtitleTrack('bitmap');
        case 'offset':
          await session.setSubtitleOffset(const Duration(milliseconds: 100));
        case 'replace':
          await session.replaceExternalSubtitles([bitmap]);
        case 'new session':
          final next = player.load(const YlFileSource('/next.mp4'));
          backend.commit(const YlPlaybackSessionId('next'));
          await next;
        case 'stop':
          await player.stop();
        case 'dispose':
          await player.dispose();
        case 'expired':
          position(3000);
      }
      cue.onRenderFailure!();
      cue.onRenderFailure!();
      if (change == 'none' || change == 'tick') {
        expect(failures, hasLength(1));
        final error = failures.single;
        expect(error.sessionId, sid);
        expect(error.failure.code, 'subtitle.resource_unavailable');
        expect(error.failure.category, YlFailureCategory.resource);
        expect(error.failure.scope, YlFailureScope.command);
        expect(error.failure.retryable, false);
        expect(player.state.status, YlPlaybackStatus.playing);
        expect(player.state.failure, isNull);
        expect(player.textSubtitleCues, isEmpty);
        position(1200);
        expect(player.textSubtitleCues, isEmpty);
        // A later palette/cue still renders; failure does not disable the track.
        position(2000);
        expect(player.textSubtitleCues, hasLength(1));
        expect(player.state.subtitles.selectedTrackId, 'bitmap');
      } else {
        expect(failures, isEmpty);
        if (change == 'reselect' || change == 'replace' || change == 'seek') {
          expect(player.textSubtitleCues, hasLength(1));
        }
      }
    });
  }

  test(
    'real file catalog, selection, offset and native revision coexist',
    () async {
      await session.replaceExternalSubtitles([sub()]);
      expect(player.state.subtitles.tracks.single.id, 'en');
      expect(player.state.subtitles.selectedTrackId, isNull);
      await session.selectSubtitleTrack('en');
      await session.setSubtitleOffset(const Duration(milliseconds: 500));
      final revision = player.state.revision;
      position(1600);
      expect(
        player.state.timeline.position,
        const Duration(milliseconds: 1600),
      );
      expect(player.state.revision, greaterThan(revision));
      expect(player.state.subtitles.selectedTrackId, 'en');
      expect(player.state.subtitles.offset, const Duration(milliseconds: 500));
      await session.replaceExternalSubtitles([]);
      expect(player.state.subtitles.tracks, isEmpty);
      expect(player.state.subtitles.selectedTrackId, isNull);
    },
  );

  test('bad replacement is atomic and sanitized', () async {
    await session.replaceExternalSubtitles([sub()]);
    await session.selectSubtitleTrack('en');
    final before = player.state;
    await file.writeAsString('secret-token malformed');
    await expectLater(
      session.replaceExternalSubtitles([sub()]),
      failure(YlFailureCodes.subtitleMalformed),
    );
    expect(player.state, before);
    await expectLater(
      session.selectSubtitleTrack('missing'),
      failure(YlFailureCodes.sourceInvalid),
    );
  });

  test(
    'managed retry reaches parser and atomically replaces selected content',
    () async {
      await session.replaceExternalSubtitles([sub()]);
      await session.selectSubtitleTrack('en');
      final before = player.state;
      final first = Completer<void>();
      final finalRequest = Completer<HttpRequest>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var count = 0;
      server.listen((r) {
        if (++count == 1) {
          r.response.statusCode = 503;
          unawaited(r.response.close());
          first.complete();
        } else {
          finalRequest.complete(r);
        }
      });
      final pending = session.replaceExternalSubtitles([
        sub(
          source: YlNetworkSource(
            Uri.parse('http://127.0.0.1:${server.port}/sub'),
            networkPolicy: const YlNetworkPolicy.managed(
              maxRetries: 1,
              baseRetryDelay: Duration.zero,
            ),
          ),
        ),
      ]);
      await first.future;
      expect(player.state, before);
      final request = await finalRequest.future;
      expect(player.state, before);
      request.response.write(sample.replaceAll('second', 'managed fresh'));
      await request.response.close();
      await pending;
      position(1600);
      backend.emitFirstFrame(sid);
      expect(player.state.subtitles.selectedTrackId, 'en');
      expect(player.textSubtitleCues.last.text.toPlainText(), 'managed fresh');
      expect(count, 2);
    },
  );

  test(
    'managed parse failure never retries or changes committed catalog',
    () async {
      await session.replaceExternalSubtitles([sub()]);
      final before = player.state;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var count = 0;
      server.listen((r) {
        count++;
        r.response.write('malformed secret');
        unawaited(r.response.close());
      });
      await expectLater(
        session.replaceExternalSubtitles([
          sub(
            source: YlNetworkSource(
              Uri.parse('http://127.0.0.1:${server.port}/sub'),
              networkPolicy: const YlNetworkPolicy.managed(
                baseRetryDelay: Duration.zero,
              ),
            ),
          ),
        ]),
        failure(YlFailureCodes.subtitleMalformed),
      );
      expect(player.state, before);
      expect(count, 1);
    },
  );

  for (final action in ['replace', 'load', 'stop', 'dispose']) {
    test(
      'managed backoff is cancelled by $action with no later requests',
      () async {
        final first = Completer<void>();
        var count = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((r) {
          count++;
          r.response.statusCode = 503;
          unawaited(r.response.close());
          if (!first.isCompleted) first.complete();
        });
        final pending = session.replaceExternalSubtitles([
          sub(
            source: YlNetworkSource(
              Uri.parse('http://127.0.0.1:${server.port}/sub'),
              networkPolicy: const YlNetworkPolicy.managed(
                baseRetryDelay: Duration(milliseconds: 200),
              ),
            ),
          ),
        ]);
        final checked = expectLater(
          pending,
          failure(switch (action) {
            'load' => YlFailureCodes.sessionStale,
            'dispose' => YlFailureCodes.playerDisposed,
            _ => YlFailureCodes.loadCancelled,
          }),
        );
        await first.future;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        if (action == 'replace') {
          await session.replaceExternalSubtitles([]);
        } else if (action == 'load') {
          final next = player.load(const YlFileSource('/next.mp4'));
          backend.commit(const YlPlaybackSessionId('next'));
          await next;
        } else if (action == 'stop') {
          backend.stopReply = Completer<void>();
          final stopping = player.stop();
          await checked;
          backend.stopReply!.complete();
          await stopping;
        } else {
          await player.dispose();
        }
        await checked.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(count, 1);
        expect(player.state.subtitles.tracks, isEmpty);
      },
    );
  }

  test(
    'events share the public revision domain after subtitle publications',
    () async {
      await session.replaceExternalSubtitles([sub()]);
      await session.selectSubtitleTrack('en');
      final events = <YlPlayerEvent>[];
      final subscription = player.events.listen(events.add);
      addTearDown(subscription.cancel);
      backend.emitFirstFrame(sid);
      expect(events.single.revision, player.state.revision);
      backend.emitState(backend.state.copyWith(revision: 100));
      // Preserve very late milestone identity without growing a revision map.
      backend.emitEvent(
        const YlFirstFrameEvent(
          sessionId: sid,
          revision: 1,
          occurredAt: Duration(milliseconds: 20),
        ),
      );
      expect(events.last.revision, player.state.revision);
      expect(events.last.occurredAt, const Duration(milliseconds: 20));
      const terminal = YlFailure(
        category: YlFailureCategory.network,
        code: YlFailureCodes.networkFailed,
        message: 'safe',
        retryable: false,
        scope: YlFailureScope.session,
        diagnosticId: 'test',
      );
      backend.emitEvent(
        const YlPlaybackFailedEvent(
          sessionId: sid,
          revision: 100,
          occurredAt: Duration(milliseconds: 30),
          failure: terminal,
        ),
      );
      expect(events.last.revision, player.state.revision);
      expect((events.last as YlPlaybackFailedEvent).failure, terminal);
      backend.emitEvent(
        YlPlaybackEngineChangedEvent(
          sessionId: sid,
          revision: 100,
          occurredAt: Duration.zero,
          previousEngine: YlPlaybackEngine.unknown,
          engine: YlPlaybackEngine.avPlayer,
        ),
      );
      expect(events.last.revision, player.state.revision);
      backend.emitEvent(
        const YlRetryScheduledEvent(
          sessionId: sid,
          revision: 100,
          occurredAt: Duration.zero,
          retryIndex: 1,
          delay: Duration.zero,
          failure: YlFailure(
            category: YlFailureCategory.network,
            code: YlFailureCodes.networkFailed,
            message: 'safe',
            retryable: true,
            scope: YlFailureScope.session,
            diagnosticId: 'test',
          ),
        ),
      );
      expect(events.last.revision, player.state.revision);
    },
  );

  for (final kind in ['content', 'encoding']) {
    test(
      'unsupported newer $kind replacement still cancels previous pending catalog',
      () async {
        await session.replaceExternalSubtitles([sub()]);
        final arrived = Completer<HttpRequest>();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen(arrived.complete);
        final old = session.replaceExternalSubtitles([
          sub(
            id: 'slow',
            source: YlNetworkSource(
              Uri.parse('http://127.0.0.1:${server.port}/sub'),
            ),
          ),
        ]);
        final checked = expectLater(old, failure(YlFailureCodes.loadCancelled));
        final request = await arrived.future;
        await expectLater(
          session.replaceExternalSubtitles([
            kind == 'content'
                ? YlExternalSubtitle(
                    id: 'new',
                    source: YlFileSource(file.path),
                    format: YlSubtitleFormat.vobsub,
                    companionSource: YlFileSource(unsupportedIndex.path),
                  )
                : sub(
                    source: YlNetworkSource(
                      Uri.parse('https://unused.test/sub'),
                      request: YlHttpRequest(
                        headers: {'accept-encoding': 'gzip'},
                      ),
                      networkPolicy: const YlNetworkPolicy.managed(),
                    ),
                  ),
          ]),
          failure(
            kind == 'content'
                ? YlFailureCodes.subtitleUnsupported
                : YlFailureCodes.policyUnsupported,
          ),
        );
        request.response.write(sample);
        await request.response.close();
        await checked;
        expect(player.state.subtitles.tracks.single.id, 'en');
      },
    );
  }

  test('session replacement clears catalog and offset', () async {
    await session.replaceExternalSubtitles([sub()]);
    await session.selectSubtitleTrack('en');
    await session.setSubtitleOffset(const Duration(milliseconds: -500));
    final pending = player.load(const YlFileSource('/next.mp4'));
    backend.commit(const YlPlaybackSessionId('next'));
    await pending;
    expect(player.state.subtitles, YlSubtitleState());
    await expectLater(
      session.selectSubtitleTrack(null),
      failure(YlFailureCodes.sessionStale),
    );
  });

  test(
    'native subtitle owner and protected output cannot silently use text overlay',
    () async {
      final native = NativeSubtitleBackend();
      await expectLater(
        YlPlayerController.create(
          platform: FakePlayerPlatform(native),
          enableTextSubtitles: true,
        ),
        failure(YlFailureCodes.policyUnsupported),
      );
      expect(native.disposeCount, 1);
      await player.dispose();
      backend = ProtectedBackend();
      player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
        enableTextSubtitles: true,
      );
      final pending = player.load(const YlFileSource('/video.mp4'));
      backend.commit(sid);
      session = await pending;
      await expectLater(
        session.replaceExternalSubtitles([sub()]),
        failure(YlFailureCodes.policyUnsupported),
      );
      expect(player.state.subtitles.tracks, isEmpty);
      expect(player.textSubtitleCues, isEmpty);
    },
  );

  for (final action in ['replace', 'load', 'stop', 'dispose']) {
    test(
      'pending HTTP catalog is cancelled by $action without late publication',
      () async {
        await session.replaceExternalSubtitles([sub()]);
        await session.selectSubtitleTrack('en');
        final arrived = Completer<void>();
        HttpRequest? held;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((r) {
          held = r;
          arrived.complete();
        });
        final pending = session.replaceExternalSubtitles([
          sub(
            id: 'slow',
            source: YlNetworkSource(
              Uri.parse('http://127.0.0.1:${server.port}/secret'),
            ),
          ),
        ]);
        final checked = expectLater(
          pending,
          failure(switch (action) {
            'load' => YlFailureCodes.sessionStale,
            'stop' => YlFailureCodes.loadCancelled,
            'dispose' => YlFailureCodes.playerDisposed,
            _ => YlFailureCodes.loadCancelled,
          }),
        );
        await arrived.future;
        if (action == 'replace') {
          await session.replaceExternalSubtitles([sub(id: 'new')]);
        } else if (action == 'load') {
          final next = player.load(const YlFileSource('/next.mp4'));
          backend.commit(const YlPlaybackSessionId('next'));
          await next;
        } else if (action == 'stop') {
          backend.stopReply = Completer<void>();
          final stopping = player.stop();
          await checked; // Cancellation is observable before the Stop ACK.
          backend.stopReply!.complete();
          await stopping;
          await expectLater(
            session.selectSubtitleTrack(null),
            failure(YlFailureCodes.sessionStale),
          );
        } else {
          await player.dispose();
        }
        await checked.timeout(const Duration(seconds: 2));
        try {
          held!.response.write(sample);
          await held!.response.close();
        } catch (_) {}
        expect(
          player.state.subtitles.tracks.map((t) => t.id),
          action == 'replace' ? ['new'] : isEmpty,
        );
      },
    );
  }

  test(
    'selection and offset during pending replacement are preserved at atomic commit',
    () async {
      await session.replaceExternalSubtitles([sub()]);
      await session.selectSubtitleTrack('en');
      final arrived = Completer<HttpRequest>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen(arrived.complete);
      final pending = session.replaceExternalSubtitles([
        sub(
          source: YlNetworkSource(
            Uri.parse('http://127.0.0.1:${server.port}/new'),
          ),
        ),
      ]);
      final request = await arrived.future;
      await session.selectSubtitleTrack(null);
      await session.setSubtitleOffset(const Duration(milliseconds: -500));
      request.response.write(sample.replaceAll('second', 'new content'));
      await request.response.close();
      await pending;
      expect(player.state.subtitles.selectedTrackId, isNull);
      expect(player.state.subtitles.offset, const Duration(milliseconds: -500));
      await session.selectSubtitleTrack('en');
      position(1100);
      backend.emitFirstFrame(sid);
      expect(player.textSubtitleCues.map((c) => c.text.toPlainText()), [
        'one & two',
        'new content',
      ]);
    },
  );

  test('aggregate bytes and cue counts reject whole catalog', () async {
    await session.replaceExternalSubtitles([sub()]);
    final before = player.state;
    final large = await File('${dir.path}/large.srt').writeAsString(
      '1\n00:00:01,000 --> 00:00:02,000\n${'x' * 16000}\n\n${'\n' * 4000}',
    );
    // Per-document input fits but 32 copies exceed the aggregate cue budget.
    String time(int i) =>
        '00:${(i ~/ 60).toString().padLeft(2, '0')}:${(i % 60).toString().padLeft(2, '0')},000';
    final many = await File('${dir.path}/many.srt').writeAsString(
      List.generate(
        400,
        (i) => '1\n${time(i)} --> ${time(i + 1)}\nx\n\n',
      ).join(),
    );
    await expectLater(
      session.replaceExternalSubtitles([
        for (var i = 0; i < 26; i++)
          sub(id: '$i', source: YlFileSource(many.path)),
      ]),
      failure(YlFailureCodes.subtitleTooLarge),
    );
    expect(player.state, before);
    // Keep valid cue payloads while exceeding aggregate encoded input.
    await large.writeAsString(
      List.generate(
        10,
        (i) =>
            '1\n00:00:${i.toString().padLeft(2, '0')},000 --> 00:00:${(i + 1).toString().padLeft(2, '0')},000\n${'x' * 16000}\n\n',
      ).join(),
    );
    await expectLater(
      session.replaceExternalSubtitles([
        for (var i = 0; i < 27; i++)
          sub(id: '$i', source: YlFileSource(large.path)),
      ]),
      failure(YlFailureCodes.subtitleTooLarge),
    );
    expect(player.state, before);
  });

  test(
    'unsupported content and encoding do not replace current catalog',
    () async {
      await session.replaceExternalSubtitles([sub()]);
      final before = player.state;
      await expectLater(
        session.replaceExternalSubtitles([
          YlExternalSubtitle(
            id: 'ass',
            source: YlFileSource(file.path),
            format: YlSubtitleFormat.vobsub,
            companionSource: YlFileSource(unsupportedIndex.path),
          ),
        ]),
        failure(YlFailureCodes.subtitleUnsupported),
      );
      await expectLater(
        session.replaceExternalSubtitles([
          sub(
            source: YlNetworkSource(
              Uri.parse('http://127.0.0.1:1/unused'),
              request: YlHttpRequest(headers: {'accept-encoding': 'gzip'}),
              networkPolicy: const YlNetworkPolicy.managed(),
            ),
          ),
        ]),
        failure(YlFailureCodes.policyUnsupported),
      );
      expect(player.state, before);
    },
  );

  test(
    'paused and buffering use media position without wall-clock advance',
    () async {
      await session.replaceExternalSubtitles([sub()]);
      await session.selectSubtitleTrack('en');
      backend.emitFirstFrame(sid);
      for (final status in [
        YlPlaybackStatus.playing,
        YlPlaybackStatus.paused,
        YlPlaybackStatus.buffering,
      ]) {
        position(1600, status: status);
        await session.setPlaybackSpeed(2);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(player.textSubtitleCues.length, 2);
      }
      position(3100);
      expect(player.textSubtitleCues, isEmpty);
      position(1600, status: YlPlaybackStatus.completed);
      expect(player.textSubtitleCues, isEmpty);
    },
  );

  test(
    'pending seek and post-ACK snapshot cannot expose pre-seek cues',
    () async {
      await session.replaceExternalSubtitles([sub()]);
      await session.selectSubtitleTrack('en');
      position(1600);
      backend.emitFirstFrame(sid);
      backend.delayCommand('seekTo', sid);
      final first = session.seekTo(Duration.zero);
      expect(player.textSubtitleCues, isEmpty);
      position(1600); // old snapshot during pending seek
      expect(player.textSubtitleCues, isEmpty);
      backend.completeCommand('seekTo', sid);
      await first;
      expect(player.textSubtitleCues, isEmpty);
      position(0);
      expect(player.textSubtitleCues, isEmpty);
      position(1600);
      expect(player.textSubtitleCues.length, 2);
    },
  );

  testWidgets('actual overlay follows position, offset, off and seek', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await session.replaceExternalSubtitles([sub()]);
      await session.selectSubtitleTrack('en');
    });
    position(1600);
    Widget view() => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 300,
          height: 300,
          child: YlPlayerView(controller: player),
        ),
      ),
    );
    await tester.pumpWidget(view());
    expect(find.text('one & two', findRichText: true), findsNothing);
    backend.emitFirstFrame(sid);
    await tester.pump();
    expect(find.text('one & two', findRichText: true), findsOneWidget);
    expect(find.text('second', findRichText: true), findsOneWidget);
    final rect = tester.getRect(find.text('one & two', findRichText: true));
    expect(rect.top, greaterThanOrEqualTo(65.625));
    expect(rect.bottom, lessThanOrEqualTo(234.375));
    position(3100);
    await tester.pump();
    expect(find.text('second', findRichText: true), findsNothing);
    await session.setSubtitleOffset(const Duration(milliseconds: 500));
    position(2100);
    await tester.pump();
    expect(find.text('second', findRichText: true), findsOneWidget);
    await session.seekTo(Duration.zero);
    await tester.pump();
    expect(find.text('second', findRichText: true), findsNothing);
    position(0);
    await tester.pump();
    expect(find.text('second', findRichText: true), findsNothing);
    position(2100);
    await tester.pump();
    expect(find.text('second', findRichText: true), findsOneWidget);
    await session.selectSubtitleTrack(null);
    await tester.pump();
    expect(find.text('second', findRichText: true), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
