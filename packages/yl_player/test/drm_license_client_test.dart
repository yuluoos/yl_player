import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/drm/license_io.dart' as transport;

Matcher code(String value) => throwsA(
  isA<YlPlayerException>().having((e) => e.failure.code, 'code', value),
);
Future<HttpServer> server(FutureOr<void> Function(HttpRequest) handle) async {
  final result = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  result.listen((r) async {
    try {
      await handle(r);
    } on SocketException {
      /* aborted test connection */
    } on HttpException {
      /* aborted test connection */
    }
  });
  addTearDown(() => result.close(force: true));
  return result;
}

YlDrmLicenseEndpoint endpoint(
  HttpServer s, {
  int maxRetries = 0,
  bool redirects = false,
  int maxBytes = 4 * 1024 * 1024,
  Duration timeout = const Duration(seconds: 3),
}) => YlDrmLicenseEndpoint(
  Uri.parse('http://127.0.0.1:${s.port}/license'),
  allowInsecureLoopback: true,
  request: YlHttpRequest(credentials: {'Authorization': 'Bearer owned-secret'}),
  replay: maxRetries == 0
      ? YlDrmPostReplay.never
      : YlDrmPostReplay.explicitlyIdempotent,
  maxRetries: maxRetries,
  allowSameOriginRedirects: redirects,
  maxResponseBytes: maxBytes,
  timeout: timeout,
);
void main() {
  late YlDrmLicenseClient client;
  setUp(() {
    client = YlDrmLicenseClient();
  });
  tearDown(() {
    client.close();
  });
  test('real POST sends opaque bytes once and returns copied bytes', () async {
    var count = 0;
    final s = await server((r) async {
      count++;
      expect(r.method, 'POST');
      expect(r.headers.value('authorization'), 'Bearer owned-secret');
      expect(r.headers.contentType?.mimeType, 'application/octet-stream');
      expect(await r.fold<List<int>>([], (a, b) => a..addAll(b)), [1, 2, 3]);
      r.response.add([4, 5, 6]);
      await r.response.close();
    });
    final reply = await client.send(endpoint(s), YlDrmBytes([1, 2, 3]));
    expect(reply.bytes, [4, 5, 6]);
    expect(count, 1);
  });
  test(
    '403 denial, 410 and 503 never invent expiry or retry by default',
    () async {
      for (final status in [403, 410, 503]) {
        var count = 0;
        final s = await server((r) async {
          count++;
          await r.drain<void>();
          r.response.statusCode = status;
          r.response.write('secret-license-body');
          await r.response.close();
        });
        await expectLater(
          client.send(endpoint(s), YlDrmBytes([1])),
          code(
            status == 403
                ? YlFailureCodes.drmLicenseDenied
                : YlFailureCodes.drmLicenseFailed,
          ),
        );
        expect(count, 1);
      }
    },
  );
  test('only explicit idempotency permits a bounded retry', () async {
    var count = 0;
    final s = await server((r) async {
      count++;
      await r.drain<void>();
      if (count == 1) {
        r.response.statusCode = 503;
      } else {
        r.response.add([8]);
      }
      await r.response.close();
    });
    expect(
      (await client.send(endpoint(s, maxRetries: 1), YlDrmBytes([1]))).bytes,
      [8],
    );
    expect(count, 2);
  });
  test(
    'cross origin never receives credentials OR challenge, even when redirects allowed',
    () async {
      var leaked = 0;
      final other = await server((r) async {
        leaked++;
        r.response.add([1]);
        await r.response.close();
      });
      final s = await server((r) async {
        await r.drain<void>();
        r.response.statusCode = 307;
        r.response.headers.set(
          'location',
          'http://127.0.0.1:${other.port}/steal',
        );
        await r.response.close();
      });
      await expectLater(
        client.send(endpoint(s, redirects: true), YlDrmBytes([7])),
        code(YlFailureCodes.drmLicenseRedirectRejected),
      );
      expect(leaked, 0);
    },
  );
  test('same origin 307 is explicit, preserves POST and credentials', () async {
    var count = 0;
    final s = await server((r) async {
      count++;
      expect(r.method, 'POST');
      expect(r.headers.value('authorization'), 'Bearer owned-secret');
      await r.drain<void>();
      if (r.uri.path == '/license') {
        r.response.statusCode = 307;
        r.response.headers.set('location', '/final');
      } else {
        r.response.add([9]);
      }
      await r.response.close();
    });
    await expectLater(
      client.send(endpoint(s), YlDrmBytes([1])),
      code(YlFailureCodes.drmLicenseRedirectRejected),
    );
    expect(count, 1);
    expect(
      (await client.send(endpoint(s, redirects: true), YlDrmBytes([1]))).bytes,
      [9],
    );
    expect(count, 3);
  });
  test(
    'oversize challenge makes no request; chunked response is bounded',
    () async {
      var count = 0;
      final s = await server((r) async {
        count++;
        await r.drain<void>();
        r.response.add([1, 2, 3, 4, 5]);
        await r.response.close();
      });
      await expectLater(
        client.send(endpoint(s), YlDrmBytes(List.filled(1024 * 1024 + 1, 0))),
        code(YlFailureCodes.drmPayloadTooLarge),
      );
      expect(count, 0);
      await expectLater(
        client.send(endpoint(s, maxBytes: 4), YlDrmBytes([1])),
        code(YlFailureCodes.drmPayloadTooLarge),
      );
      expect(count, 1);
    },
  );
  test(
    'deadline includes body and cancellation discards late response',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var count = 0;
      final s = await server((r) async {
        await r.drain<void>();
        count++;
        r.response.add([5]);
        await r.response.flush();
        if (count == 2) entered.complete();
        await release.future;
        r.response.add([99]);
        await r.response.close();
      });
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await expectLater(
        client.send(
          endpoint(s, timeout: const Duration(milliseconds: 100)),
          YlDrmBytes([1]),
        ),
        code(YlFailureCodes.drmLicenseTimeout),
      );
      final token = YlDrmCancellationToken();
      final pending = expectLater(
        client.send(endpoint(s), YlDrmBytes([1]), cancellation: token),
        code(YlFailureCodes.loadCancelled),
      );
      await entered.future;
      token.cancel();
      release.complete();
      await pending;
      await expectLater(
        client.send(endpoint(s), YlDrmBytes([1]), cancellation: token),
        code(YlFailureCodes.loadCancelled),
      );
    },
  );
  test(
    'connection loss after POST does not trigger an implicit replay',
    () async {
      var count = 0;
      final s = await server((r) async {
        count++;
        await r.drain<void>();
        final socket = await r.response.detachSocket(writeHeaders: false);
        socket.destroy();
      });
      await expectLater(
        client.send(endpoint(s), YlDrmBytes([1])),
        code(YlFailureCodes.drmLicenseFailed),
      );
      expect(count, 1);
    },
  );
  test(
    'four requests bound concurrency and close cancels all pending requests',
    () async {
      var count = 0;
      final entered = Completer<void>();
      final release = Completer<void>();
      final s = await server((r) async {
        await r.drain<void>();
        if (++count == 4) entered.complete();
        await release.future;
        r.response.add([99]);
        await r.response.close();
      });
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final pending = [
        for (var i = 0; i < 4; i++)
          expectLater(
            client.send(endpoint(s), YlDrmBytes([i])),
            code(YlFailureCodes.loadCancelled),
          ),
      ];
      await entered.future;
      await expectLater(
        client.send(endpoint(s), YlDrmBytes([1])),
        code(YlFailureCodes.resourceExhausted),
      );
      expect(count, 4);
      client.close();
      release.complete();
      await Future.wait(pending);
    },
  );
  test('redirect loop and method-changing redirect are rejected', () async {
    var count = 0;
    final s = await server((r) async {
      count++;
      await r.drain<void>();
      r.response.statusCode = 307;
      r.response.headers.set('location', '/license');
      await r.response.close();
    });
    await expectLater(
      client.send(endpoint(s, redirects: true), YlDrmBytes([1])),
      code(YlFailureCodes.drmLicenseRedirectRejected),
    );
    expect(count, 1);
    final other = await server((r) async {
      await r.drain<void>();
      r.response.statusCode = 303;
      r.response.headers.set('location', '/different');
      await r.response.close();
    });
    await expectLater(
      client.send(endpoint(other, redirects: true), YlDrmBytes([1])),
      code(YlFailureCodes.drmLicenseRedirectRejected),
    );
  });
  test(
    'HTTPS verifies certificates and preserves a large binary POST',
    () async {
      final fixture =
          Directory.current.path.endsWith('/yl_player/packages/yl_player')
          ? 'test/fixtures/drm_tls'
          : 'packages/yl_player/test/fixtures/drm_tls';
      final cert = File('$fixture/server.pem').readAsBytesSync();
      final context = SecurityContext()
        ..useCertificateChainBytes(cert)
        ..usePrivateKey('$fixture/server.key');
      final listener = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      addTearDown(() => listener.close(force: true));
      final payload = List<int>.generate(1024 * 1024, (i) => i % 251);
      var count = 0;
      listener.listen((r) async {
        count++;
        expect(r.method, 'POST');
        final body = await r.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(body, payload);
        r.response.add(payload);
        await r.response.close();
      }, onError: (Object _) {}); // expected initial certificate rejection
      final policy = YlDrmLicenseEndpoint(
        Uri.parse('https://127.0.0.1:${listener.port}/license'),
      );
      await expectLater(
        client.send(policy, YlDrmBytes([1])),
        code(YlFailureCodes.drmLicenseFailed),
      );
      expect(count, 0);
      final trusted = SecurityContext()
        ..setTrustedCertificatesBytes(
          File('$fixture/ca.pem').readAsBytesSync(),
        );
      expect(
        (await transport.sendLicense(
          policy,
          YlDrmBytes(payload),
          YlDrmCancellationToken(),
          securityContext: trusted,
        )).bytes,
        payload,
      );
      expect(count, 1);
    },
  );
  for (final cancel in [false, true]) {
    test(
      'stalled TLS ${cancel ? "cancellation" : "timeout"} closes the peer socket',
      () async {
        // TCP accepts ClientHello but deliberately never answers the handshake.
        final listener = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final peers = <Socket>[];
        var hello = Completer<void>();
        var closed = Completer<void>();
        listener.listen((socket) {
          peers.add(socket);
          final thisHello = hello;
          final thisClosed = closed;
          socket.listen(
            (_) {
              if (!thisHello.isCompleted) thisHello.complete();
            },
            onDone: () {
              if (!thisClosed.isCompleted) thisClosed.complete();
            },
            onError: (Object _) {
              if (!thisClosed.isCompleted) thisClosed.complete();
            },
          );
        });
        addTearDown(() async {
          for (final socket in peers) {
            socket.destroy();
          }
          await listener.close();
        });
        // Repeat beyond the concurrent quota: every previous socket must close.
        for (var i = 0; i < 5; i++) {
          hello = Completer<void>();
          closed = Completer<void>();
          final token = YlDrmCancellationToken();
          final pending = expectLater(
            client.send(
              YlDrmLicenseEndpoint(
                Uri.parse('https://127.0.0.1:${listener.port}/license'),
                timeout: Duration(milliseconds: cancel ? 3000 : 300),
              ),
              YlDrmBytes([1]),
              cancellation: token,
            ),
            code(
              cancel
                  ? YlFailureCodes.loadCancelled
                  : YlFailureCodes.drmLicenseTimeout,
            ),
          );
          await hello.future.timeout(const Duration(seconds: 2));
          if (cancel) token.cancel();
          await pending;
          await closed.future.timeout(const Duration(seconds: 1));
        }
        expect(peers, hasLength(5));
      },
    );
  }
  test('empty response rejected and closed client cannot send', () async {
    final s = await server((r) async {
      await r.drain<void>();
      await r.response.close();
    });
    await expectLater(
      client.send(endpoint(s), YlDrmBytes([1])),
      code(YlFailureCodes.drmLicenseResponseInvalid),
    );
    client.close();
    await expectLater(
      client.send(endpoint(s), YlDrmBytes([1])),
      code(YlFailureCodes.loadCancelled),
    );
  });
}
