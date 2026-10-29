import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';

enum _Race { manifest, media }

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final evidence = <String, Object>{};
  for (final race in _Race.values) {
    testWidgets(
      'Dart concurrent credentials: ${race.name} response loses to new Load',
      (tester) async {
        final origin = await _RaceOrigin.start(race);
        addTearDown(origin.close);
        final player = await appleController(tester);
        final states = <YlPlayerState>[];
        final events = <YlPlayerEvent>[];
        final stateSubscription = player.states.listen(states.add);
        final eventSubscription = player.events.listen(events.add);
        addTearDown(stateSubscription.cancel);
        addTearDown(eventSubscription.cancel);
        YlNetworkSource source(String marker) => YlNetworkSource(
          origin.uri('/movie.mpd'),
          format: YlMediaFormat.dash,
          request: YlHttpRequest(
            headers: {'X-Client': 'ordinary', 'X-Fixture-Load': marker},
            credentials: {
              'Authorization': '$marker-fixture',
              'Cookie': '$marker-fixture',
              'X-Session': '$marker-fixture',
            },
          ),
        );
        YlPlaybackSession? old;
        Future<void>? cancellation;
        if (race == _Race.manifest) {
          // Attach the observer before the replacing Load can reject this Future.
          cancellation = expectLater(
            player.load(source('old')),
            throwsA(
              isA<YlPlayerException>().having(
                (e) => e.failure.code,
                'code',
                YlFailureCodes.loadCancelled,
              ),
            ),
          );
        } else {
          old = await player.load(source('old'));
        }
        await origin.held.future.timeout(const Duration(seconds: 5));
        expect(origin.released, isFalse);
        final winner = await player
            .load(source('winner'))
            .timeout(const Duration(seconds: 5));
        if (cancellation != null) {
          await cancellation.timeout(const Duration(seconds: 5));
        }
        expect(
          origin.released,
          isFalse,
          reason: 'Old Load must lose before its held response is released',
        );
        origin.trace.add('winner-committed');
        final winnerStateIndex = states.length;
        await readyAndPlay(player, winner);
        origin.trace.add('winner-first-frame');
        await origin.winnerReturned.future.timeout(const Duration(seconds: 5));
        final position = player.state.timeline.position;
        origin.release();
        await origin.completed.future.timeout(const Duration(seconds: 5));
        await stateWhere(
          player,
          (state) =>
              state.sessionId == winner.id &&
              state.timeline.position >
                  position + const Duration(milliseconds: 500),
        );
        await winner.pause();
        expect(player.state.sessionId, winner.id);
        expect(player.state.failure, isNull);
        expect(
          states
              .skip(winnerStateIndex)
              .every((state) => state.sessionId == winner.id),
          isTrue,
        );
        expect(events.whereType<YlPlaybackFailedEvent>(), isEmpty);
        expect(
          events.whereType<YlFirstFrameEvent>().any(
            (event) => event.sessionId == winner.id,
          ),
          isTrue,
        );
        if (old != null) {
          expect(old.id, isNot(winner.id));
          await expectLater(
            old.firstFrame,
            throwsA(
              isA<YlPlayerException>().having(
                (e) => e.failure.code,
                'code',
                YlFailureCodes.sessionStale,
              ),
            ),
          );
          await expectLater(
            old.pause(),
            throwsA(
              isA<YlPlayerException>().having(
                (e) => e.failure.code,
                'code',
                YlFailureCodes.sessionStale,
              ),
            ),
          );
        } else {
          expect(
            states
                .where((state) => state.sessionId != null)
                .every((state) => state.sessionId == winner.id),
            isTrue,
          );
        }
        origin.verify();
        evidence[race.name] = {
          'trace': origin.trace,
          'requests': origin.safeRequests,
          'winnerFirstFrame': true,
          'winnerProgressAfterRelease': true,
        };
        binding.reportData = evidence;
        debugPrint(
          'credential-race ${race.name}: ${jsonEncode(evidence[race.name])}',
        );
      },
    );
  }
}

// Fixed synthetic credentials, owned loopback origins, deterministic response gates.
final class _RaceOrigin {
  _RaceOrigin(this.race, this.primary, this.secondary, this.files);
  final _Race race;
  final HttpServer primary, secondary;
  final Map<String, Uint8List> files;
  final requests =
      <
        ({
          String origin,
          String path,
          String marker,
          Map<String, String> headers,
        })
      >[];
  final trace = <String>[];
  final held = Completer<void>(),
      completed = Completer<void>(),
      winnerReturned = Completer<void>();
  final _release = Completer<void>();
  bool released = false;
  bool _closed = false;
  final errors = <Object>[];
  static Future<_RaceOrigin> start(_Race race) async {
    final files = <String, Uint8List>{};
    for (final name in [
      'init-0.m4s',
      for (var i = 1; i <= 4; i++)
        'chunk-0-${i.toString().padLeft(5, '0')}.m4s',
    ]) {
      final bytes = await rootBundle.load(
        'assets/test_media/dash/period0/$name',
      );
      files['/$name'] = bytes.buffer.asUint8List(
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      );
    }
    final primary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final secondary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final result = _RaceOrigin(race, primary, secondary, files);
      primary.listen((r) => result.handle('primary', r));
      secondary.listen((r) => result.handle('secondary', r));
      return result;
    } catch (_) {
      await primary.close(force: true);
      rethrow;
    }
  }

  Uri uri(String path, {bool other = false}) => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: (other ? secondary : primary).port,
    path: path,
  );
  void release() {
    if (!released) {
      released = true;
      trace.add('old-released');
      _release.complete();
    }
  }

  Future<void> handle(String origin, HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach((k, v) => headers[k] = v.join(','));
    final marker = headers['x-fixture-load'] ?? 'missing',
        path = request.uri.path;
    requests.add((
      origin: origin,
      path: path,
      marker: marker,
      headers: headers,
    ));
    trace.add('$marker:$origin:$path');
    final isHeld =
        marker == 'old' &&
        (race == _Race.manifest
            ? path == '/returned/movie.mpd'
            : path == '/hop/init-0.m4s');
    try {
      if (isHeld) {
        if (!held.isCompleted) held.complete();
        await _release.future;
      }
      if (_closed) return;
      final response = request.response;
      response.persistentConnection = false;
      if (path == '/movie.mpd' && marker == 'old' && race == _Race.manifest) {
        response.statusCode = 302;
        response.headers.set(
          HttpHeaders.locationHeader,
          uri('/hop/movie.mpd', other: true),
        );
      } else if (path.startsWith('/hop/')) {
        response.statusCode = 302;
        response.headers.set(
          HttpHeaders.locationHeader,
          uri(path.replaceFirst('/hop/', '/returned/')),
        );
      } else if (path.endsWith('/movie.mpd')) {
        final bytes = utf8.encode(_manifest);
        response.headers.contentType = ContentType('application', 'dash+xml');
        response.contentLength = bytes.length;
        response.add(bytes);
      } else if (path == '/init-0.m4s') {
        response.statusCode = 302;
        response.headers.set(
          HttpHeaders.locationHeader,
          uri('/hop/init-0.m4s', other: true),
        );
      } else {
        final resource = path.replaceFirst('/returned/', '/');
        final bytes = files[resource];
        if (bytes == null) {
          response.statusCode = 404;
        } else {
          response.headers.contentType = ContentType('video', 'mp4');
          response.contentLength = bytes.length;
          response.add(bytes);
        }
        if (marker == 'winner' &&
            path == '/returned/init-0.m4s' &&
            !winnerReturned.isCompleted) {
          winnerReturned.complete();
        }
      }
      await response.close();
    } catch (error) {
      // The intentionally superseded request can already have a closed peer.
      if (!isHeld || (error is! HttpException && error is! SocketException)) {
        errors.add(error);
      }
    } finally {
      if (isHeld && !completed.isCompleted) {
        trace.add('old-handler-completed');
        completed.complete();
      }
    }
  }

  List<Map<String, Object>> get safeRequests => [
    for (final r in requests)
      {
        'origin': r.origin,
        'path': r.path,
        'load': r.marker,
        'authorization': r.headers.containsKey('authorization'),
        'cookie': r.headers.containsKey('cookie'),
        'sessionCredential': r.headers.containsKey('x-session'),
      },
  ];
  void verify() {
    expect(errors, isEmpty);
    for (final marker in ['old', 'winner']) {
      final root = requests.where(
        (r) => r.path == '/movie.mpd' && r.marker == marker,
      );
      expect(root, isNotEmpty);
      for (final r in root) {
        for (final key in ['authorization', 'cookie', 'x-session']) {
          expect(r.headers[key], '$marker-fixture');
        }
      }
    }
    expect(
      requests.any((r) => r.marker == 'winner' && r.path == '/init-0.m4s'),
      isTrue,
    );
    final initRequests = requests
        .where((r) => r.marker == 'winner' && r.path == '/init-0.m4s')
        .toList();
    for (final key in ['authorization', 'cookie', 'x-session']) {
      expect(initRequests.first.headers[key], 'winner-fixture');
    }
    final crossed = requests.indexWhere(
      (r) => r.marker == 'winner' && r.path == '/hop/init-0.m4s',
    );
    for (final r
        in requests
            .skip(crossed + 1)
            .where((r) => r.marker == 'winner' && r.path == '/init-0.m4s')) {
      for (final key in ['authorization', 'cookie', 'x-session']) {
        expect(r.headers[key], isNull);
      }
    }
    for (final r in requests) {
      expect(r.headers['x-client'], 'ordinary');
      expect(r.marker, isIn(['old', 'winner']));
      if (r.origin == 'secondary' || r.path.startsWith('/returned/')) {
        for (final key in ['authorization', 'cookie', 'x-session']) {
          expect(r.headers[key], isNull, reason: '${r.marker}:${r.path}:$key');
        }
      } else if (r.marker == 'winner' &&
          !r.path.endsWith('.mpd') &&
          r.path != '/init-0.m4s') {
        // Stripping one init resource must not poison other same-origin media.
        for (final key in ['authorization', 'cookie', 'x-session']) {
          expect(r.headers[key], 'winner-fixture');
        }
      }
    }
    if (race == _Race.manifest) {
      expect(
        requests.any(
          (r) => r.marker == 'old' && r.path == '/returned/movie.mpd',
        ),
        isTrue,
      );
      expect(
        requests.any((r) => r.marker == 'old' && r.path.endsWith('.m4s')),
        isFalse,
      );
    } else {
      expect(
        requests.any((r) => r.marker == 'old' && r.path == '/hop/init-0.m4s'),
        isTrue,
      );
    }
    for (final path in ['/hop/init-0.m4s', '/returned/init-0.m4s']) {
      expect(
        requests.any((r) => r.marker == 'winner' && r.path == path),
        isTrue,
      );
    }
    expect(
      trace.indexOf('winner-first-frame'),
      lessThan(trace.indexOf('old-released')),
    );
    expect(
      trace.indexOf('old-released'),
      lessThan(trace.indexOf('old-handler-completed')),
    );
  }

  Future<void> close() async {
    _closed = true;
    release();
    await primary.close(force: true);
    await secondary.close(force: true);
  }
}

const _manifest =
    r'''<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT4S"><Period duration="PT4S"><AdaptationSet contentType="video"><Representation id="0" mimeType="video/mp4" codecs="avc1.42c01e" bandwidth="350000" width="320" height="180" frameRate="24/1"><SegmentTemplate timescale="12288" initialization="init-0.m4s" media="chunk-0-$Number%05d$.m4s" startNumber="1"><SegmentTimeline><S t="0" d="12288" r="3"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>''';
