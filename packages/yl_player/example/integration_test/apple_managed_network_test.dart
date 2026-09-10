import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/range_media_server.dart';
import 'ios_hls_headers_playback_test.dart' as authenticated_hls;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // This loopback AES-128 HLS fixture must actually play and inspect every
  // origin/child request. No generic unsupported/error escape is accepted.
  authenticated_hls.main();
  for (final (format, extension) in [
    (YlMediaFormat.matroska, 'mkv'),
    (YlMediaFormat.flv, 'flv'),
  ]) {
    testWidgets(
      'managed $extension retries exactly once then positively plays',
      (tester) async {
        final server = await RangeMediaServer.start(
          asset: 'assets/test_media/h264_aac.$extension',
          scriptedResponses: const [RangeMediaResponse.status(503)],
        );
        addTearDown(server.close);
        final controller = await appleController(tester);
        final retries = <YlRetryScheduledEvent>[];
        final subscription = controller.events.listen((e) {
          if (e is YlRetryScheduledEvent) retries.add(e);
        });
        addTearDown(subscription.cancel);
        final session = await controller.load(
          YlNetworkSource(
            server.mediaUri,
            format: format,
            networkPolicy: strictNetwork,
            request: YlHttpRequest(
              headers: const {'X-Strict-Fixture': 'managed-positive'},
            ),
          ),
          options: const YlLoadOptions(),
        );
        await readyAndPlay(controller, session);
        expect(controller.state.engine, YlPlaybackEngine.managedFallback);
        expect(server.requests, hasLength(2));
        expect(server.requests.map((r) => r.statusCode), [
          503,
          extension == 'mkv' ? 206 : 200,
        ]);
        expect(
          server.requests.every(
            (r) => r.header('x-strict-fixture') == 'managed-positive',
          ),
          isTrue,
        );
        expect(
          server.requests.every(
            (r) =>
                r.header('range') == (extension == 'mkv' ? 'bytes=0-' : null),
          ),
          isTrue,
        );
        expect(controller.state.metrics.managedBufferedBytes, isNull);
        // Preparation retries precede a committed session and may have no public
        // session event. Exact wire attempts are the authoritative proof here.
        expect(retries.length, lessThanOrEqualTo(1));
      },
    );
  }
  testWidgets(
    'managed cross-origin redirect strips credentials and preserves ordinary headers',
    (tester) async {
      final destination = await RangeMediaServer.start(
        asset: 'assets/test_media/h264_aac.mkv',
      );
      addTearDown(destination.close);
      final source = await RangeMediaServer.start(
        asset: 'assets/test_media/h264_aac.mkv',
        redirectUri: destination.mediaUri,
        scriptedResponses: const [RangeMediaResponse.redirect()],
      );
      addTearDown(source.close);
      final controller = await appleController(tester);
      final session = await controller.load(
        YlNetworkSource(
          source.mediaUri,
          format: YlMediaFormat.matroska,
          networkPolicy: strictNetwork,
          request: YlHttpRequest(
            headers: const {'X-Ordinary': 'keep'},
            credentials: const {
              'Authorization': 'Bearer fixture-only',
              'X-Secret': 'fixture-only',
            },
          ),
        ),
        options: const YlLoadOptions(),
      );
      await readyAndPlay(controller, session);
      expect(source.requests, hasLength(1));
      expect(
        source.requests.single.header('authorization'),
        'Bearer fixture-only',
      );
      expect(destination.requests, isNotEmpty);
      for (final request in destination.requests) {
        expect(request.header('authorization'), isNull);
        expect(request.header('x-secret'), isNull);
        expect(request.header('x-ordinary'), 'keep');
      }
    },
  );
  testWidgets(
    'managed header deadline rejects with exact zero retry request count',
    (tester) async {
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final server = await RangeMediaServer.start(
        asset: 'assets/test_media/h264_aac.mkv',
        beforeResponse: (_) => release.future,
      );
      addTearDown(server.close);
      final controller = await appleController(tester);
      await expectLater(
        controller.load(
          YlNetworkSource(
            server.mediaUri,
            format: YlMediaFormat.matroska,
            networkPolicy: const YlNetworkPolicy.managed(
              connectTimeout: Duration(milliseconds: 200),
              readTimeout: Duration(seconds: 2),
              maxRetries: 0,
            ),
          ),
        ),
        failureCode('network.retry_exhausted'),
      );
      expect(server.requests, hasLength(1));
      expect(controller.state.sessionId, isNull);
    },
  );
  testWidgets(
    'unsupported strict routes reject before any upstream request or replacement',
    (tester) async {
      final server = await RangeMediaServer.start(
        asset: 'assets/test_media/h264_aac.mkv',
      );
      addTearDown(server.close);
      final controller = await appleController(tester);
      final old = await controller.load(
        YlNetworkSource(server.mediaUri, format: YlMediaFormat.matroska),
      );
      await readyAndPlay(controller, old);
      final requests = server.requests.length;
      for (final format in [
        YlMediaFormat.hls,
        YlMediaFormat.mp4,
        YlMediaFormat.mov,
        YlMediaFormat.avi,
        YlMediaFormat.mpegTs,
        YlMediaFormat.mpegPs,
      ]) {
        for (final (policy, options) in [
          (strictNetwork, const YlLoadOptions()),
          (
            const YlNetworkPolicy.platformDefault(),
            const YlLoadOptions(bufferStrategy: strictBuffer),
          ),
          (
            const YlNetworkPolicy.platformDefault(),
            const YlLoadOptions(
              decoderPolicyOverride: YlDecoderPolicy.hardwareRequired,
            ),
          ),
        ]) {
          await expectLater(
            controller.load(
              YlNetworkSource(
                server.mediaUri,
                format: format,
                networkPolicy: policy,
              ),
              options: options,
            ),
            failureCode(YlFailureCodes.policyUnsupported),
          );
          expect(controller.state.sessionId, old.id);
          expect(server.requests.length, requests);
        }
      }
      await old.pause();
      await old.play();
    },
  );
}
