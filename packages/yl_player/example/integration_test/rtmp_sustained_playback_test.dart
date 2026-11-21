import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'rtmp_playback_test.dart' as rtmp;
import 'support/apple_strict_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('owned RTMP advances for ten minutes on one connection', (
    tester,
  ) async {
    final player = await appleController(tester);
    final before = await rtmp.control('normal');
    expect(before['active'], 0);
    final session = await rtmp.render(player);
    var lastPosition = player.state.timeline.position;
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(minutes: 10)) {
      await Future<void>.delayed(const Duration(seconds: 5));
      final state = player.state;
      expect(state.sessionId, session.id);
      expect(state.failure, isNull);
      expect(state.timeline.position, greaterThan(lastPosition));
      lastPosition = state.timeline.position;
      debugPrint(
        'YL_FOLLOWUP_SOAK=${jsonEncode({'elapsedMs': clock.elapsedMilliseconds, 'positionMs': lastPosition.inMilliseconds, 'status': state.status.name, 'rebufferCount': state.metrics.rebufferCount, 'sessionId': session.id.value})}',
      );
    }
    debugPrint('YL_FOLLOWUP_STOP=issued');
    await player.stop();
    await stateWhere(player, (s) => s.status == YlPlaybackStatus.idle);
    expect(player.state.sessionId, isNull);
    debugPrint('YL_FOLLOWUP_STOP=idle');
    final peer = await _closedPeer();
    expect(peer['accepted'], (before['accepted'] as int) + 1);
    expect(peer['closed'], (before['closed'] as int) + 1);
  }, timeout: const Timeout(Duration(minutes: 13)));
}

// The control connection can time out independently of the media connection.
// Only this read-only observation is retried. Stop is issued exactly once.
Future<Map<String, dynamic>> _closedPeer() async {
  final deadline = Stopwatch()..start();
  while (deadline.elapsed < const Duration(seconds: 20)) {
    try {
      final peer = await rtmp.control('stats');
      if (peer['active'] == 0) return peer;
    } on TimeoutException {
      // Reopen the control connection on the next poll.
    } on SocketException {
      // The control connection may have closed before delivering the response.
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw TimeoutException('No post-stop peer receipt');
}
