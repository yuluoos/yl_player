import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final cases = <(String, String, String)>[
    (
      '<MPD><private-dash-secret>',
      YlFailureCodes.dashManifestInvalid,
      'valid UTF-8 MPD',
    ),
    (
      '<MPD type="dynamic" id="private-dash-secret"/>',
      YlFailureCodes.dashDynamicUnsupported,
      'static DASH',
    ),
    (
      '<MPD><ContentProtection value="private-dash-secret"/></MPD>',
      YlFailureCodes.dashProtectionUnsupported,
      'protected-content declaration',
    ),
    (
      '<MPD><SegmentBase indexRange="private-dash-secret"/></MPD>',
      YlFailureCodes.dashSegmentBaseUnsupported,
      'SegmentTemplate or SegmentList',
    ),
    (' ' * (2 * 1024 * 1024 + 1), YlFailureCodes.dashManifestTooLarge, '2 MiB'),
  ];
  for (final (manifest, code, guidance) in cases) {
    testWidgets('DASH admission publishes safe $code and permits recovery', (
      tester,
    ) async {
      final bad = await DashServer.start(manifestOverride: manifest);
      final good = await DashServer.start();
      addTearDown(bad.close);
      addTearDown(good.close);
      final player = await appleController(tester);
      YlFailure? observed;
      try {
        await player.load(
          YlNetworkSource(
            bad.automaticUri.replace(
              queryParameters: {'token': 'private-dash-secret'},
            ),
            request: YlHttpRequest(
              credentials: const {
                'Authorization': 'Bearer private-dash-secret',
              },
            ),
          ),
        );
        fail('Rejected MPD unexpectedly loaded');
      } on YlPlayerException catch (error) {
        observed = error.failure;
      }
      final failure = observed;
      expect(failure.code, code);
      expect(
        failure.category,
        code == YlFailureCodes.dashManifestTooLarge
            ? YlFailureCategory.resource
            : YlFailureCategory.container,
      );
      expect(failure.message, contains(guidance));
      expect(failure.retryable, isFalse);
      expect(failure.scope, YlFailureScope.command);
      expect(failure.diagnosticId, startsWith('apple-'));
      for (final privateText in [
        'private-dash-secret',
        '127.0.0.1',
        'Authorization',
        'Bearer',
        '?token=',
      ]) {
        expect(failure.toString().contains(privateText), isFalse);
      }
      expect(bad.requests, hasLength(1));
      expect(bad.requests.single.path, '/manifest.mpd');
      final session = await player.load(YlNetworkSource(good.automaticUri));
      await readyAndPlay(player, session);
      await stateWhere(
        player,
        (state) => state.timeline.position > const Duration(milliseconds: 300),
      );
      expect(player.state.sessionId, session.id);
      expect(player.state.failure, isNull);
      expect(good.requests.any((r) => r.path.endsWith('.m4s')), isTrue);
      await player.stop();
      debugPrint(
        'DASH diagnostic $code: safe command failure, root=1, subsequent firstFrame and progress',
      );
    });
  }
}
