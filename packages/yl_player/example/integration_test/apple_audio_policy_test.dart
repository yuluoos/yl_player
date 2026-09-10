import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/authenticated_hls_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final policy in YlAudioPolicy.values) {
    testWidgets(
      '${Platform.isIOS ? 'iOS' : 'macOS'} public two-player audio lifecycle ${policy.name}',
      (tester) async {
        final server = await AuthenticatedHlsServer.start(sameOrigin: true);
        addTearDown(server.close);
        final first = await appleController(tester, audioPolicy: policy);
        final second = await appleController(tester, audioPolicy: policy);
        final source = YlNetworkSource(
          server.masterUri,
          format: YlMediaFormat.hls,
        );
        final a = await first.load(source);
        await readyAndPlay(first, a);
        final b = await second.load(source);
        await readyAndPlay(second, b);
        await a.pause();
        await first.dispose();
        await b.pause();
        await b.play();
        expect(second.state.sessionId, b.id);
        expect(second.state.failure, isNull);
        await second.stop();
        await stateWhere(second, (s) => s.sessionId == null);
        // Native RunnerTests separately observe the real iOS driver and exact
        // process-wide lease calls. Public API intentionally has no global-state
        // readback; this test does not claim cross-FlutterEngine/device evidence.
      },
    );
  }
}
