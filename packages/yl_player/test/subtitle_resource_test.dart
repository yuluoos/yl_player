import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'package:yl_player/yl_player.dart';

Matcher failure(String code) => throwsA(
  isA<YlPlayerException>()
      .having((e) => e.failure.code, 'code', code)
      .having((e) => e.failure.scope, 'scope', YlFailureScope.command)
      .having((e) => e.failure.retryable, 'retryable', false),
);

void main() {
  late SubtitleCancellation token;
  setUp(() => token = SubtitleCancellation());
  tearDown(() => token.cancel());
  test(
    'explicit nonidentity encoding request is rejected, never overwritten',
    () async {
      await expectLater(
        readSubtitleResource(
          YlNetworkSource(
            Uri.parse('http://127.0.0.1:1/unused'),
            request: YlHttpRequest(headers: {'Accept-Encoding': 'gzip'}),
          ),
          token,
          100,
        ),
        failure(YlFailureCodes.policyUnsupported),
      );
    },
  );
  Future<HttpServer> serve(void Function(HttpRequest) handle) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handle);
    addTearDown(() => server.close(force: true));
    return server;
  }

  Uri url(HttpServer server, [String path = '/sub']) =>
      Uri.parse('http://127.0.0.1:${server.port}$path');

  test('actual GET preserves headers and same-origin credentials', () async {
    final seen = <String?>[];
    final server = await serve((r) {
      seen.add(r.headers.value('authorization'));
      expect(r.headers.value('x-language'), 'en');
      if (r.uri.path == '/sub') {
        r.response.statusCode = 302;
        r.response.headers.set('location', '/final');
      } else {
        r.response.write('owned subtitle');
      }
      unawaited(r.response.close());
    });
    final bytes = await readSubtitleResource(
      YlNetworkSource(
        url(server),
        request: YlHttpRequest(
          headers: {'x-language': 'en'},
          credentials: {'authorization': 'secret'},
        ),
      ),
      token,
      100,
    );
    expect(utf8.decode(bytes), 'owned subtitle');
    expect(seen, ['secret', 'secret']);
  });

  test(
    'cross-origin redirect strips credentials permanently including return',
    () async {
      late HttpServer origin;
      final seen = <String?>[];
      final other = await serve((r) {
        seen.add(r.headers.value('authorization'));
        expect(r.headers.value('x-language'), 'en');
        r.response.statusCode = 302;
        r.response.headers.set('location', url(origin, '/back').toString());
        unawaited(r.response.close());
      });
      origin = await serve((r) {
        seen.add(r.headers.value('authorization'));
        if (r.uri.path == '/sub') {
          r.response.statusCode = 302;
          r.response.headers.set('location', url(other).toString());
        } else {
          r.response.write('ok');
        }
        unawaited(r.response.close());
      });
      expect(
        await readSubtitleResource(
          YlNetworkSource(
            url(origin),
            request: YlHttpRequest(
              headers: {'x-language': 'en'},
              credentials: {'authorization': 'secret'},
            ),
          ),
          token,
          100,
        ),
        utf8.encode('ok'),
      );
      expect(seen, ['secret', null, null]);
    },
  );

  for (final declared in [true, false]) {
    test('bounded HTTP body declared=$declared', () async {
      final server = await serve((r) {
        if (declared) r.response.contentLength = 101;
        r.response.add(List.filled(101, 65));
        unawaited(r.response.close());
      });
      await expectLater(
        readSubtitleResource(YlNetworkSource(url(server)), token, 100),
        failure(YlFailureCodes.subtitleTooLarge),
      );
    });
  }
  test('redirect budget stops a loop after five hops', () async {
    var count = 0;
    final server = await serve((r) {
      count++;
      r.response.statusCode = 302;
      r.response.headers.set('location', '/sub');
      unawaited(r.response.close());
    });
    await expectLater(
      readSubtitleResource(YlNetworkSource(url(server)), token, 100),
      failure(YlFailureCodes.networkFailed),
    );
    expect(count, 6);
  });
  test('HTTP errors are sanitized and never retried', () async {
    var count = 0;
    final server = await serve((r) {
      count++;
      r.response.statusCode = 503;
      r.response.write('secret server details');
      unawaited(r.response.close());
    });
    try {
      await readSubtitleResource(YlNetworkSource(url(server)), token, 100);
      fail('must fail');
    } on YlPlayerException catch (e) {
      expect(e.failure.code, YlFailureCodes.networkFailed);
      expect(e.toString(), isNot(contains('secret')));
      expect(e.failure.message, isNot(contains('127.0.0.1')));
    }
    expect(count, 1);
  });
  test('managed policy now performs the request', () async {
    var count = 0;
    final server = await serve((r) {
      count++;
      r.response.write('managed');
      unawaited(r.response.close());
    });
    expect(
      await readSubtitleResource(
        YlNetworkSource(
          url(server),
          networkPolicy: const YlNetworkPolicy.managed(),
        ),
        token,
        100,
      ),
      utf8.encode('managed'),
    );
    expect(count, 1);
  });
  test(
    'encoded responses reject rather than bypassing decompressed budget',
    () async {
      final server = await serve((r) {
        r.response.headers.set('content-encoding', 'gzip');
        r.response.add(gzip.encode(utf8.encode('owned')));
        unawaited(r.response.close());
      });
      await expectLater(
        readSubtitleResource(YlNetworkSource(url(server)), token, 100),
        failure(YlFailureCodes.subtitleUnsupported),
      );
    },
  );
  for (final sendBody in [false, true]) {
    test(
      'cancellation closes stalled ${sendBody ? 'body' : 'headers'}',
      () async {
        final arrived = Completer<void>();
        final server = await serve((r) {
          if (sendBody) {
            r.response.write('start');
            unawaited(r.response.flush());
          }
          arrived.complete();
        });
        final pending = readSubtitleResource(
          YlNetworkSource(url(server)),
          token,
          100,
        );
        final checked = expectLater(
          pending,
          failure(YlFailureCodes.loadCancelled),
        );
        await arrived.future;
        token.cancel();
        await checked.timeout(const Duration(seconds: 2));
      },
    );
  }
  test('cancellation owns and closes a stalled TLS handshake socket', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final connected = Completer<void>();
    final closed = Completer<void>();
    Socket? socket;
    server.listen((s) {
      socket = s;
      s.listen(
        (_) {
          if (!connected.isCompleted) connected.complete();
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
      );
    });
    addTearDown(() async {
      socket?.destroy();
      await server.close();
    });
    final checked = expectLater(
      readSubtitleResource(
        YlNetworkSource(Uri.parse('https://127.0.0.1:${server.port}/secret')),
        token,
        100,
      ),
      failure(YlFailureCodes.loadCancelled),
    );
    await connected.future.timeout(const Duration(seconds: 2));
    token.cancel();
    await checked.timeout(const Duration(seconds: 2));
    await closed.future.timeout(const Duration(seconds: 2));
  });
  test(
    'file streams enforce input limit and missing paths are sanitized',
    () async {
      final dir = await Directory.systemTemp.createTemp('yl-subtitle-budget-');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File(
        '${dir.path}/owned',
      ).writeAsBytes(List.filled(101, 65));
      await expectLater(
        readSubtitleResource(YlFileSource(file.path), token, 100),
        failure(YlFailureCodes.subtitleTooLarge),
      );
      await expectLater(
        readSubtitleResource(
          YlFileSource('${dir.path}/secret-missing'),
          token,
          100,
        ),
        failure(YlFailureCodes.sourceMissing),
      );
    },
  );
}
