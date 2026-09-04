import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/authenticated_hls_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('HLS headers follow the same-origin credential policy', (
    WidgetTester tester,
  ) async {
    final server = await AuthenticatedHlsServer.start();
    addTearDown(server.close);
    final controller = YlPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: controller)),
    );
    final firstFrameOrError = controller.events
        .firstWhere(
          (event) => event is YlFirstFrameEvent || event is YlErrorEvent,
        )
        .timeout(const Duration(seconds: 20));

    await controller.open(
      YlMediaSource.network(
        server.masterUri,
        formatHint: YlFormatHint.hls,
        headers: const <String, String>{
          'Authorization': 'Bearer same-origin-secret',
          'Cookie': 'session=same-origin-secret',
          'Proxy-Authorization': 'Basic same-origin-proxy-secret',
          'X-Client': 'yl-player-test',
        },
      ),
    );
    await controller.play();
    try {
      final event = await firstFrameOrError;
      if (event case YlErrorEvent(:final error)) {
        fail('HLS failed: $error; requests: ${_requestSummary(server)}');
      }
    } on TimeoutException {
      fail(
        'HLS first frame timed out; state: ${controller.state.status}/'
        '${controller.state.error}; requests: ${_requestSummary(server)}',
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

    for (final request in <RecordedHlsRequest>[
      ...masterRequests,
      ...keyRequests,
    ]) {
      expect(request.origin, 'primary');
      expect(request.header('authorization'), 'Bearer same-origin-secret');
      expect(request.header('cookie'), 'session=same-origin-secret');
      expect(
        request.header('proxy-authorization'),
        'Basic same-origin-proxy-secret',
      );
      expect(request.header('x-client'), 'yl-player-test');
    }
    for (final request in <RecordedHlsRequest>[
      ...childRequests,
      ...segmentRequests,
    ]) {
      expect(request.origin, 'secondary');
      expect(request.header('authorization'), isNull);
      expect(request.header('cookie'), isNull);
      expect(request.header('proxy-authorization'), isNull);
      expect(request.header('x-client'), 'yl-player-test');
    }

    expect(controller.state.engine, YlPlaybackEngine.avPlayer);
  });
}

String _requestSummary(AuthenticatedHlsServer server) => server.requests
    .map(
      (request) =>
          '${request.origin}:${request.path}[${request.header('range') ?? '-'}]',
    )
    .join(', ');
