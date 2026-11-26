import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

// Supply a host for which the device's active resolver returns a negative answer.
const _missingHost = String.fromEnvironment('YL_ANDROID_UNRESOLVABLE_HOST');
const _network = YlNetworkPolicy.managed(maxRetries: 0);

Future<YlFailure> _observeFailure(
  YlPlayerController player,
  YlNetworkSource source,
) async {
  try {
    final session = await player
        .load(source)
        .timeout(const Duration(seconds: 25));
    await session.play();
    final state = await stateWhere(player, (s) => s.failure != null);
    return state.failure!;
  } on YlPlayerException catch (error) {
    return error.failure;
  }
}

void _checkFailure(YlFailure failure, String code, String host) {
  expect(failure.code, code);
  expect(failure.diagnosticId, isNotEmpty);
  expect(failure.message, isNotEmpty);
  expect(failure.message, isNot(contains(host)));
  expect(failure.message, isNot(contains('private-stream')));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('closing RTMP during client handshake reports setup failure', (
    tester,
  ) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final versions = <int>[];
    final subscription = server.listen((socket) {
      socket.first
          .then((data) {
            if (data.isNotEmpty) versions.add(data.first);
          })
          .whenComplete(socket.destroy);
    });
    addTearDown(subscription.cancel);
    final player = await appleController(tester);
    final failure = await _observeFailure(
      player,
      YlNetworkSource(
        Uri.parse('rtmp://127.0.0.1:${server.port}/live/private-stream'),
      ),
    );
    _checkFailure(
      failure,
      YlFailureCodes.networkRtmpHandshakeFailed,
      '127.0.0.1',
    );
    expect(versions, [3]);
    expect(player.state.sessionId, isNull);
  });

  for (final child in [false, true]) {
    final boundary = child ? 'segment' : 'manifest';
    testWidgets(
      'Android classifies DNS failure at DASH $boundary request',
      (tester) async {
        await expectLater(
          InternetAddress.lookup(
            _missingHost,
          ).timeout(const Duration(seconds: 10)),
          throwsA(isA<SocketException>()),
          reason: 'The device must observe a failed lookup before playback.',
        );
        debugPrint('YL_DNS_LOOKUP boundary=$boundary result=failed');
        final player = await appleController(tester);
        // The debug app permits cleartext only for the loopback fixture.
        Uri uri = Uri.https(_missingHost, '/private-stream.mpd');
        DashServer? server;
        if (child) {
          final manifest = await rootBundle.loadString(
            'assets/test_media/dash_variants/manifest.mpd',
          );
          server = await DashServer.start(
            manifestOverride: manifest.replaceAll(
              '<BaseURL>period',
              '<BaseURL>https://$_missingHost/private-stream/period',
            ),
          );
          addTearDown(server.close);
          uri = server.automaticUri;
        }
        final failure = await _observeFailure(
          player,
          YlNetworkSource(
            uri,
            format: YlMediaFormat.dash,
            networkPolicy: _network,
          ),
        );
        _checkFailure(failure, YlFailureCodes.networkDnsFailed, _missingHost);
        if (server != null) {
          await server.settle();
          expect(server.requestsFor('/manifest.mpd'), isNotEmpty);
          expect(server.childRequests, isEmpty);
        }
        debugPrint('YL_DNS_RESULT boundary=$boundary code=${failure.code}');
      },
      skip: _missingHost.isEmpty,
    );
  }
}
