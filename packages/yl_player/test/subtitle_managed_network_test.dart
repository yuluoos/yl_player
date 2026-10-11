import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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
  Future<HttpServer> serve(void Function(HttpRequest) handle) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handle);
    addTearDown(() => server.close(force: true));
    return server;
  }

  YlNetworkSource source(
    HttpServer server, {
    YlNetworkPolicy policy = const YlNetworkPolicy.managed(
      maxRetries: 2,
      baseRetryDelay: Duration.zero,
      maxRetryDelay: Duration.zero,
    ),
  }) => YlNetworkSource(
    Uri.parse('http://127.0.0.1:${server.port}/sub'),
    networkPolicy: policy,
  );

  for (final status in [408, 429, 500, 502, 503, 504]) {
    test('managed retries HTTP $status through successful body', () async {
      var count = 0;
      final server = await serve((r) {
        if (++count < 3) {
          r.response.statusCode = status;
          r.response.write('discard');
        } else {
          r.response.write('owned');
        }
        unawaited(r.response.close());
      });
      expect(
        utf8.decode(await readSubtitleResource(source(server), token, 100)),
        'owned',
      );
      expect(count, 3);
    });
  }
  test('managed retry count excludes initial attempt', () async {
    var count = 0;
    final server = await serve((r) {
      count++;
      r.response.statusCode = 503;
      unawaited(r.response.close());
    });
    await expectLater(
      readSubtitleResource(source(server), token, 100),
      failure(YlFailureCodes.networkFailed),
    );
    expect(count, 3);
  });
  test('response header timeout is retried and closes held request', () async {
    var count = 0;
    final server = await serve((r) {
      if (++count > 1) {
        r.response.write('ok');
        unawaited(r.response.close());
      }
    });
    expect(
      await readSubtitleResource(
        source(
          server,
          policy: const YlNetworkPolicy.managed(
            connectTimeout: Duration(milliseconds: 150),
            maxRetries: 1,
            baseRetryDelay: Duration.zero,
          ),
        ),
        token,
        100,
      ),
      utf8.encode('ok'),
    );
    expect(count, 2);
  });
  test('read inactivity retry discards prior attempt bytes', () async {
    var count = 0;
    final server = await serve((r) {
      if (++count == 1) {
        r.response.write('old-partial');
        unawaited(r.response.flush());
      } else {
        r.response.write('fresh');
        unawaited(r.response.close());
      }
    });
    expect(
      utf8.decode(
        await readSubtitleResource(
          source(
            server,
            policy: const YlNetworkPolicy.managed(
              readTimeout: Duration(milliseconds: 150),
              maxRetries: 1,
              baseRetryDelay: Duration.zero,
            ),
          ),
          token,
          100,
        ),
      ),
      'fresh',
    );
    expect(count, 2);
  });

  for (final status in [400, 401, 403, 404, 501]) {
    test('permanent HTTP $status never retries', () async {
      var count = 0;
      final server = await serve((r) {
        count++;
        r.response.statusCode = status;
        unawaited(r.response.close());
      });
      await expectLater(
        readSubtitleResource(source(server), token, 100),
        failure(YlFailureCodes.networkFailed),
      );
      expect(count, 1);
    });
  }
  test(
    'body progress resets read deadline after connect deadline has expired',
    () async {
      final sent = Completer<void>();
      final server = await serve((r) {
        r.response.bufferOutput = false;
        unawaited(() async {
          for (var i = 0; i < 6; i++) {
            r.response.write('x');
            await r.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 70));
          }
          await r.response.close();
          sent.complete();
        }());
      });
      expect(
        await readSubtitleResource(
          source(
            server,
            policy: const YlNetworkPolicy.managed(
              connectTimeout: Duration(milliseconds: 200),
              readTimeout: Duration(milliseconds: 250),
              maxRetries: 0,
            ),
          ),
          token,
          100,
        ),
        utf8.encode('xxxxxx'),
      );
      await sent.future;
    },
  );
  for (final value in [
    '1',
    '999999999999999999999999',
    'Sun, 11 Oct 2099 12:00:00 GMT',
  ]) {
    test('excessive valid Retry-After forbids retry: $value', () async {
      var count = 0;
      final server = await serve((r) {
        count++;
        r.response.statusCode = 503;
        r.response.headers.set('retry-after', value);
        unawaited(r.response.close());
      });
      await expectLater(
        readSubtitleResource(source(server), token, 100),
        failure(YlFailureCodes.networkFailed),
      );
      expect(count, 1);
    });
  }
  test(
    'Retry-After zero overrides delay and malformed values fall back',
    () async {
      final times = <int>[];
      final watch = Stopwatch()..start();
      final server = await serve((r) {
        times.add(watch.elapsedMilliseconds);
        if (times.length < 3) {
          r.response.statusCode = 503;
          r.response.headers.set(
            'retry-after',
            times.length == 1 ? '0' : 'invalid',
          );
        } else {
          r.response.write('ok');
        }
        unawaited(r.response.close());
      });
      expect(
        await readSubtitleResource(
          source(
            server,
            policy: const YlNetworkPolicy.managed(
              maxRetries: 2,
              baseRetryDelay: Duration(milliseconds: 100),
              maxRetryDelay: Duration(milliseconds: 250),
            ),
          ),
          token,
          100,
        ),
        utf8.encode('ok'),
      );
      expect(times.length, 3);
      expect(times[2] - times[1], greaterThanOrEqualTo(180));
    },
  );
  test('exponential backoff saturates in actual request scheduling', () async {
    final times = <int>[];
    final watch = Stopwatch()..start();
    final server = await serve((r) {
      times.add(watch.elapsedMilliseconds);
      if (times.length < 4) {
        r.response.statusCode = 503;
      } else {
        r.response.write('ok');
      }
      unawaited(r.response.close());
    });
    await readSubtitleResource(
      source(
        server,
        policy: const YlNetworkPolicy.managed(
          maxRetries: 3,
          baseRetryDelay: Duration(milliseconds: 80),
          maxRetryDelay: Duration(milliseconds: 120),
        ),
      ),
      token,
      100,
    );
    expect(times.length, 4);
    for (var i = 1; i < 4; i++) {
      expect(times[i] - times[i - 1], greaterThanOrEqualTo(i == 1 ? 65 : 100));
    }
  });
  test('cancel during backoff prevents all later attempts', () async {
    var count = 0;
    final first = Completer<void>();
    final server = await serve((r) {
      count++;
      r.response.statusCode = 503;
      unawaited(r.response.close());
      if (!first.isCompleted) first.complete();
    });
    final checked = expectLater(
      readSubtitleResource(
        source(
          server,
          policy: const YlNetworkPolicy.managed(
            baseRetryDelay: Duration(milliseconds: 200),
          ),
        ),
        token,
        100,
      ),
      failure(YlFailureCodes.loadCancelled),
    );
    await first.future;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    token.cancel();
    await checked.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(count, 1);
  });
  test(
    'redirect counter spans retries and credentials stay stripped on return',
    () async {
      late HttpServer origin;
      final credentials = <String?>[];
      final paths = <String>[];
      var failures = 0;
      final other = await serve((r) {
        credentials.add(r.headers.value('authorization'));
        paths.add('other');
        if (failures++ == 0) {
          r.response.statusCode = 503;
        } else {
          r.response.statusCode = 302;
          r.response.headers.set(
            'location',
            'http://127.0.0.1:${origin.port}/back',
          );
        }
        unawaited(r.response.close());
      });
      origin = await serve((r) {
        credentials.add(r.headers.value('authorization'));
        paths.add(r.uri.path);
        if (r.uri.path == '/sub') {
          r.response.statusCode = 302;
          r.response.headers.set(
            'location',
            'http://127.0.0.1:${other.port}/other',
          );
        } else {
          r.response.statusCode = 302;
          r.response.headers.set('location', '/over-budget');
        }
        unawaited(r.response.close());
      });
      await expectLater(
        readSubtitleResource(
          YlNetworkSource(
            source(origin).uri,
            request: YlHttpRequest(credentials: {'authorization': 'secret'}),
            networkPolicy: const YlNetworkPolicy.managed(
              maxRetries: 1,
              maxRedirects: 2,
              baseRetryDelay: Duration.zero,
            ),
          ),
          token,
          100,
        ),
        failure(YlFailureCodes.networkFailed),
      );
      expect(paths, ['/sub', 'other', 'other', '/back']);
      expect(credentials, ['secret', null, null, null]);
    },
  );
  for (final which in ['redirect', 'retry']) {
    test('zero $which budget rejects first such response', () async {
      var count = 0;
      final server = await serve((r) {
        count++;
        r.response.statusCode = which == 'redirect' ? 302 : 503;
        r.response.headers.set('location', '/again');
        unawaited(r.response.close());
      });
      await expectLater(
        readSubtitleResource(
          source(
            server,
            policy: const YlNetworkPolicy.managed(
              maxRedirects: 0,
              maxRetries: 0,
            ),
          ),
          token,
          100,
        ),
        failure(YlFailureCodes.networkFailed),
      );
      expect(count, 1);
    });
  }
  for (final which in ['encoding', 'length', 'stream']) {
    test('terminal $which error never retries', () async {
      var count = 0;
      final server = await serve((r) {
        count++;
        if (which == 'encoding') {
          r.response.headers.set('content-encoding', 'gzip');
        }
        if (which == 'length') r.response.contentLength = 101;
        r.response.add(List.filled(101, 65));
        unawaited(r.response.close());
      });
      await expectLater(
        readSubtitleResource(source(server), token, 100),
        failure(
          which == 'encoding'
              ? YlFailureCodes.subtitleUnsupported
              : YlFailureCodes.subtitleTooLarge,
        ),
      );
      expect(count, 1);
    });
  }
  test(
    'TCP reset during response headers retries owned attempt',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
      });
      var count = 0;
      server.listen((socket) {
        sockets.add(socket);
        final attempt = ++count;
        var replied = false;
        socket.listen((_) async {
          if (replied) return;
          replied = true;
          if (attempt == 1) {
            // POSIX struct linger { int l_onoff; int l_linger; }. A zero
            // linger timeout makes close send RST, rather than graceful EOF.
            final linger = Int32List.fromList([1, 0]).buffer.asUint8List();
            socket.setRawOption(
              RawSocketOption(
                RawSocketOption.levelSocket,
                Platform.isMacOS ? 0x80 : 13,
                linger,
              ),
            );
            socket.destroy();
          } else {
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nfresh',
            );
            await socket.flush();
            await socket.close();
          }
        }, onError: (Object _) {});
      });
      final bytes = await readSubtitleResource(
        YlNetworkSource(
          Uri.parse('http://127.0.0.1:${server.port}/sub'),
          networkPolicy: const YlNetworkPolicy.managed(
            maxRetries: 1,
            baseRetryDelay: Duration.zero,
          ),
        ),
        token,
        100,
      );
      expect(utf8.decode(bytes), 'fresh');
      expect(count, 2);
    },
    skip: !(Platform.isMacOS || Platform.isLinux),
  );
  for (final malformed in [false, true]) {
    test(
      'raw ${malformed ? 'invalid protocol rejects' : 'truncated body retries from empty'}',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <Socket>[];
        addTearDown(() async {
          for (final s in sockets) {
            s.destroy();
          }
          await server.close();
        });
        var count = 0;
        server.listen((s) {
          sockets.add(s);
          final attempt = ++count;
          var replied = false;
          s.listen((_) async {
            if (replied) return;
            replied = true;
            s.write(
              malformed
                  ? 'NOT HTTP\r\n\r\n'
                  : attempt == 1
                  ? 'HTTP/1.1 200 OK\r\nContent-Length: 50\r\nConnection: close\r\n\r\nold'
                  : 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nfresh',
            );
            await s.flush();
            await s.close();
          });
        });
        final pending = readSubtitleResource(
          YlNetworkSource(
            Uri.parse('http://127.0.0.1:${server.port}/sub'),
            networkPolicy: const YlNetworkPolicy.managed(
              maxRetries: 1,
              baseRetryDelay: Duration.zero,
            ),
          ),
          token,
          100,
        );
        if (malformed) {
          await expectLater(pending, failure(YlFailureCodes.networkFailed));
          expect(count, 1);
        } else {
          expect(utf8.decode(await pending), 'fresh');
          expect(count, 2);
        }
      },
    );
  }
  test(
    'TLS header timeout owns and closes every handshake before retry',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final closed = <Completer<void>>[];
      server.listen((s) {
        sockets.add(s);
        final done = Completer<void>();
        closed.add(done);
        s.listen(
          (_) {},
          onDone: done.complete,
          onError: (Object _) {
            if (!done.isCompleted) done.complete();
          },
        );
      });
      addTearDown(() async {
        for (final s in sockets) {
          s.destroy();
        }
        await server.close();
      });
      await expectLater(
        readSubtitleResource(
          YlNetworkSource(
            Uri.parse('https://127.0.0.1:${server.port}/sub'),
            networkPolicy: const YlNetworkPolicy.managed(
              connectTimeout: Duration(milliseconds: 150),
              maxRetries: 1,
              baseRetryDelay: Duration.zero,
            ),
          ),
          token,
          100,
        ),
        failure(YlFailureCodes.networkFailed),
      );
      expect(sockets.length, 2);
      await Future.wait(
        closed.map((c) => c.future),
      ).timeout(const Duration(seconds: 2));
    },
  );
  test(
    'certificate failure is terminal even with remaining retry budget',
    () async {
      final context = SecurityContext()
        ..useCertificateChain(
          'packages/yl_player/test/fixtures/drm_tls/server.pem',
        )
        ..usePrivateKey('packages/yl_player/test/fixtures/drm_tls/server.key');
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      server.listen((s) {
        sockets.add(s);
        unawaited(
          SecureSocket.secureServer(
            s,
            context,
          ).then<void>((secure) => secure.destroy(), onError: (Object _) {}),
        );
      });
      addTearDown(() async {
        for (final s in sockets) {
          s.destroy();
        }
        await server.close();
      });
      await expectLater(
        readSubtitleResource(
          YlNetworkSource(
            Uri.parse('https://127.0.0.1:${server.port}/secret'),
            networkPolicy: const YlNetworkPolicy.managed(
              maxRetries: 3,
              baseRetryDelay: Duration.zero,
            ),
          ),
          token,
          100,
        ),
        failure(YlFailureCodes.networkFailed),
      );
      expect(sockets.length, 1);
    },
  );
}
