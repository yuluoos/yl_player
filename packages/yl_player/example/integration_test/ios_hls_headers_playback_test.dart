import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/playback_sessions.dart';

import 'support/authenticated_hls_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final sameOrigin in [true, false]) {
    testWidgets(
      'HLS credentials ${sameOrigin ? 'reach same-origin children' : 'stay stripped after crossing origins'}',
      (WidgetTester tester) async {
        final server = await AuthenticatedHlsServer.start(
          sameOrigin: sameOrigin,
        );
        addTearDown(server.close);
        final controller = await YlPlayerController.create();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(home: YlPlayerView(controller: controller)),
        );
        final firstFrameOrError = controller.events
            .firstWhere(
              (event) =>
                  event is YlFirstFrameEvent || event is YlPlaybackFailedEvent,
            )
            .timeout(const Duration(seconds: 20));

        await loadSession(
          controller,
          YlNetworkSource(
            server.masterUri,
            format: YlMediaFormat.hls,
            request: YlHttpRequest(
              headers: const {'X-Client': 'yl-player-test'},
              credentials: const <String, String>{
                'X-Session': 'custom-origin-secret',
                'Authorization': 'Bearer same-origin-secret',
                'Cookie': 'session=same-origin-secret',
                'Proxy-Authorization': 'Basic same-origin-proxy-secret',
              },
            ),
          ),
        );
        await sessionFor(controller).play();
        await sessionFor(controller).ready.timeout(const Duration(seconds: 20));
        try {
          final event = await firstFrameOrError;
          if (event case YlPlaybackFailedEvent(:final failure)) {
            fail('HLS failed: $failure; requests: ${_requestSummary(server)}');
          }
        } on TimeoutException {
          fail(
            'HLS first frame timed out; state: ${controller.state.status}/'
            '${controller.state.failure}; requests: ${_requestSummary(server)}',
          );
        }

        final masterRequests = server.requestsFor('/master.m3u8');
        final keyRequests = server.requestsFor('/key.bin');
        final childRequests = server.requestsFor('/media.m3u8');
        final segmentRequests = server.requestsFor('/segment0.ts');
        expect(masterRequests, isNotEmpty);
        expect(keyRequests, isNotEmpty);
        expect(childRequests, isNotEmpty);
        expect(segmentRequests, isNotEmpty);

        final credentialRequests = <RecordedHlsRequest>[
          ...masterRequests,
          if (sameOrigin) ...[
            ...keyRequests,
            ...childRequests,
            ...segmentRequests,
          ],
        ];
        for (final request in credentialRequests) {
          expect(request.origin, 'primary');
          expect(request.header('authorization'), 'Bearer same-origin-secret');
          expect(request.header('cookie'), 'session=same-origin-secret');
          expect(
            request.header('proxy-authorization'),
            'Basic same-origin-proxy-secret',
          );
          expect(request.header('x-session'), 'custom-origin-secret');
          expect(request.header('x-client'), 'yl-player-test');
        }
        if (!sameOrigin) {
          for (final request in [
            ...childRequests,
            ...segmentRequests,
            ...keyRequests,
          ]) {
            expect(
              request.origin,
              request.path == '/key.bin' ? 'primary' : 'secondary',
            );
            expect(request.header('authorization'), isNull);
            expect(request.header('cookie'), isNull);
            expect(request.header('proxy-authorization'), isNull);
            expect(request.header('x-session'), isNull);
            expect(request.header('x-client'), 'yl-player-test');
          }
        }

        expect(controller.state.engine, YlPlaybackEngine.avPlayer);
      },
    );
  }
}

String _requestSummary(AuthenticatedHlsServer server) => server.requests
    .map(
      (request) =>
          '${request.origin}:${request.path}[${request.header('range') ?? '-'}]',
    )
    .join(', ');
