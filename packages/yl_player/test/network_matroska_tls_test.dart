import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/matroska_fixture.dart';
import 'support/range_server.dart';

void main() {
  late HttpOverrides? previous;
  setUp(() {
    previous = HttpOverrides.current;
    HttpOverrides.global = null;
  });
  tearDown(() {
    HttpOverrides.global = previous;
  });
  SecurityContext context() => SecurityContext()
    ..useCertificateChain('packages/yl_player/test/fixtures/drm_tls/server.pem')
    ..usePrivateKey('packages/yl_player/test/fixtures/drm_tls/server.key');
  test('untrusted HTTPS certificate never consumes retries', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final tls = context();
    server.listen((s) {
      sockets.add(s);
      unawaited(
        SecureSocket.secureServer(
          s,
          tls,
        ).then<void>((socket) => socket.destroy(), onError: (Object _) {}),
      );
    });
    addTearDown(() async {
      for (final s in sockets) {
        s.destroy();
      }
      await server.close();
    });
    final runtime = TextSubtitleRuntime();
    addTearDown(runtime.reset);
    await expectLater(
      runtime.discover(
        YlNetworkSource(
          Uri.parse('https://127.0.0.1:${server.port}/private'),
          networkPolicy: const YlNetworkPolicy.managed(
            maxRetries: 3,
            baseRetryDelay: Duration.zero,
          ),
        ),
      ),
      throwsA(
        isA<YlPlayerException>().having(
          (e) => e.failure.code,
          'code',
          YlFailureCodes.networkFailed,
        ),
      ),
    );
    expect(sockets, hasLength(1));
  });
  test(
    'trusted HTTPS range discovery works; downgrade never contacts HTTP target',
    () async {
      // Trust the owned test CA in this test-file VM only; production trust is unchanged.
      SecurityContext.defaultContext.setTrustedCertificates(
        'packages/yl_player/test/fixtures/drm_tls/server.pem',
      );
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context(),
      );
      final fixture = RangeServer(
        server,
        mkv(extra: element(0xec, List.filled(40000, 0))),
      );
      final target = await RangeServer.start(mkv());
      var redirect = false;
      var requests = 0;
      server.listen((q) {
        requests++;
        if (redirect) {
          q.response.statusCode = 302;
          q.response.headers.set('location', target.uri.toString());
          unawaited(q.response.close());
        } else {
          fixture.reply(q);
        }
      });
      addTearDown(() async {
        await server.close(force: true);
        await target.close();
      });
      final runtime = TextSubtitleRuntime();
      addTearDown(runtime.reset);
      final source = YlNetworkSource(
        Uri.parse('https://127.0.0.1:${server.port}/media'),
        networkPolicy: const YlNetworkPolicy.managed(maxRetries: 0),
      );
      await runtime.discover(source);
      runtime.select('mkv:101');
      expect(
        runtime.cuesAt(const Duration(seconds: 1)).single.text.toPlainText(),
        'hello',
      );
      expect(requests, greaterThan(1));
      final old = runtime.state;
      redirect = true;
      await expectLater(
        runtime.discover(source),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.networkFailed,
          ),
        ),
      );
      expect(target.requests, isEmpty);
      expect(runtime.state, old);
    },
  );
}
