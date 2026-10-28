import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Dart Load isolates credentials after committed media failure', (
    tester,
  ) async {
    final origin = await _FailureOrigin.start();
    addTearDown(origin.close);
    final player = await appleController(tester);
    final failures = <YlPlaybackFailedEvent>[];
    final events = player.events.listen((event) {
      if (event is YlPlaybackFailedEvent) failures.add(event);
    });
    addTearDown(events.cancel);

    YlNetworkSource source(String token) => YlNetworkSource(
      origin.uri('/movie.mpd'),
      format: YlMediaFormat.dash,
      request: YlHttpRequest(
        headers: {
          'X-Client': 'ordinary',
          'X-Fixture-Load': token == 'first-fixture' ? 'one' : 'two',
        },
        credentials: {
          'Authorization': token,
          'Cookie': token,
          'X-Session': token,
        },
      ),
    );

    Future<void> failed(YlPlaybackSession session) async {
      await expectLater(
        session.ready.timeout(const Duration(seconds: 5)),
        throwsA(isA<YlPlayerException>()),
      );
      await expectLater(
        session.firstFrame.timeout(const Duration(seconds: 5)),
        throwsA(isA<YlPlayerException>()),
      );
      await stateWhere(
        player,
        (state) =>
            state.sessionId == session.id &&
            state.status == YlPlaybackStatus.failed,
      );
      expect(player.state.failure, isNotNull);
      // Failed state settles milestones before the separately acknowledged event.
      if (!failures.any((event) => event.sessionId == session.id)) {
        await player.events
            .firstWhere(
              (event) =>
                  event is YlPlaybackFailedEvent &&
                  event.sessionId == session.id,
            )
            .timeout(const Duration(seconds: 5));
      }

      expect(
        failures.where((event) => event.sessionId == session.id),
        hasLength(1),
      );
    }

    // The returned session proves Load committed before the media readiness error.
    final first = await player.load(source('first-fixture'));
    await failed(first);
    await origin.returned('one');
    expect(origin.sent('/init.mp4', 'first-fixture'), isTrue);
    final second = await player.load(source('second-fixture'));
    expect(second.id, isNot(first.id));
    await failed(second);
    await origin.returned('two');
    expect(origin.sent('/init.mp4', 'second-fixture'), isTrue);
    await expectLater(
      first.pause(),
      throwsA(
        isA<YlPlayerException>().having(
          (error) => error.failure.code,
          'code',
          YlFailureCodes.sessionStale,
        ),
      ),
    );
    expect(player.state.sessionId, second.id);
    expect(origin.requests.where((r) => r.path == '/hop'), isNotEmpty);
    expect(origin.requests.where((r) => r.path == '/gone.mp4'), isNotEmpty);
    for (final marker in ['one', 'two']) {
      for (final path in ['/hop', '/gone.mp4']) {
        expect(
          origin.requests.any(
            (r) => r.path == path && r.headers['x-fixture-load'] == marker,
          ),
          isTrue,
        );
      }
    }
    for (final request in origin.requests) {
      expect(request.headers['x-client'], 'ordinary');
      if (request.path == '/hop' || request.path == '/gone.mp4') {
        for (final key in ['authorization', 'cookie', 'x-session']) {
          expect(request.headers[key], isNull, reason: '${request.path}: $key');
        }
      }
    }
    debugPrint(
      'credential-failure: 2 committed sessions, 2 failures, '
      '${origin.requests.length} origin requests, cross-origin credentials absent',
    );
  });
}

// Owned loopback origins only. Fixed synthetic credentials never leave this app.
final class _FailureOrigin {
  _FailureOrigin(this.primary, this.secondary);
  final HttpServer primary;
  final HttpServer secondary;
  final requests = <({String path, Map<String, String> headers})>[];
  final _returned = <String, Completer<void>>{};
  Future<void> returned(String marker) => _returned
      .putIfAbsent(marker, Completer<void>.new)
      .future
      .timeout(const Duration(seconds: 5));

  static Future<_FailureOrigin> start() async {
    final primary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final secondary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = _FailureOrigin(primary, secondary);
      primary.listen(origin.handle);
      secondary.listen(origin.handle);
      return origin;
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

  bool sent(String path, String token) => requests.any(
    (request) =>
        request.path == path &&
        [
          'authorization',
          'cookie',
          'x-session',
        ].every((key) => request.headers[key] == token),
  );

  void handle(HttpRequest request) {
    final headers = <String, String>{};
    request.headers.forEach((key, values) => headers[key] = values.join(','));
    requests.add((path: request.uri.path, headers: headers));
    if (request.uri.path == '/gone.mp4') {
      final marker = headers['x-fixture-load'];
      if (marker != null) {
        final done = _returned.putIfAbsent(marker, Completer<void>.new);
        if (!done.isCompleted) done.complete();
      }
    }
    final response = request.response;
    response.persistentConnection = false;
    switch (request.uri.path) {
      case '/movie.mpd':
        final data = utf8.encode(_manifest);
        response.headers.contentType = ContentType('application', 'dash+xml');
        response.contentLength = data.length;
        response.add(data);
      case '/init.mp4':
        response.statusCode = HttpStatus.found;
        response.headers.set(
          HttpHeaders.locationHeader,
          uri('/hop', other: true),
        );
      case '/hop':
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader, uri('/gone.mp4'));
      default:
        response.statusCode = HttpStatus.gone;
        response.headers.contentType = ContentType('video', 'mp4');
    }
    unawaited(response.close());
  }

  Future<void> close() async {
    await primary.close(force: true);
    await secondary.close(force: true);
  }
}

const _manifest =
    r'''<MPD type="static" mediaPresentationDuration="PT4S"><Period><AdaptationSet mimeType="video/mp4"><Representation id="v" bandwidth="1000" codecs="avc1.64001f" width="320" height="180"><SegmentTemplate initialization="init.mp4" media="seg-$Number$.m4s" duration="2"/></Representation></AdaptationSet></Period></MPD>''';
