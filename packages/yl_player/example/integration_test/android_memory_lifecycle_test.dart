import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/range_media_server.dart';

// Host sends RUNNING_CRITICAL, HOME and foreground at the respective markers.
// Observations use each committed session's actual Media3 allocator on its worker.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const probe = MethodChannel('yl_player_example/debug/frame_observation');
  testWidgets('two Mi TV sessions trim, background, rebuild and release', (
    tester,
  ) async {
    final server = await RangeMediaServer.start(
      asset: 'assets/test_media/network_seek_h264_aac.mkv',
    );
    addTearDown(server.close);
    final source = YlNetworkSource(
      server.mediaUri,
      format: YlMediaFormat.matroska,
    );
    const options = YlPlayerOptions(audioPolicy: YlAudioPolicy.appManaged);
    final first = await YlPlayerController.create(options: options);
    addTearDown(first.dispose);
    final second = await YlPlayerController.create(options: options);
    addTearDown(second.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          children: [
            for (final player in [first, second])
              Expanded(child: YlPlayerView(controller: player)),
          ],
        ),
      ),
    );
    final old = await first.load(source);
    await readyAndPlay(first, old);
    await old.pause();
    await stateWhere(first, (s) => s.status == YlPlaybackStatus.paused);
    final active = await second.load(source);
    await readyAndPlay(second, active);
    await stateWhere(second, (s) => s.timeline.position.inMilliseconds > 400);

    Future<Map<String, int>> budget(YlPlaybackSession session) async {
      await probe.invokeMethod('installActive', {
        'sessionId': session.id.value,
      });
      try {
        return (await probe.invokeMapMethod<String, int>('bufferBudget'))!;
      } finally {
        await probe.invokeMethod('remove');
      }
    }

    Future<List<Map<String, int>>> budgets(String phase) async {
      final values = [await budget(old), await budget(active)];
      debugPrint('YL_MEMORY_BUDGET phase=$phase values=${jsonEncode(values)}');
      return values;
    }

    final normal = await budgets('normal');
    final expected = normal[1]['normalBytes']! ~/ 4 * 3;
    expect(normal[0]['allocatedBytes'], 0);
    expect(normal.every((row) => row['targetBytes']! > 0), isTrue);
    debugPrint('YL_MEMORY_PHASE=trim');
    final deadline = Stopwatch()..start();
    late List<Map<String, int>> reduced;
    do {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      reduced = [await budget(old), await budget(active)];
    } while (deadline.elapsed < const Duration(seconds: 10) &&
        reduced[1]['targetBytes'] != expected);
    debugPrint('YL_MEMORY_BUDGET phase=reduced values=${jsonEncode(reduced)}');
    // The suspended lease has already returned all allocator blocks.
    expect(reduced[0]['allocatedBytes'], 0);
    expect(reduced[1]['targetBytes'], expected);
    expect(reduced[1]['allocatedBytes'], inInclusiveRange(1, expected));
    final trimmedAt = second.state.timeline.position;
    await stateWhere(
      second,
      (s) =>
          s.status == YlPlaybackStatus.playing &&
          s.timeline.position > trimmedAt + const Duration(milliseconds: 500),
    );
    await probe.invokeMethod('installActive', {'sessionId': active.id.value});
    debugPrint('YL_MEMORY_PHASE=background');
    await stateWhere(second, (s) => s.status == YlPlaybackStatus.paused);
    final held = second.state.timeline.position;
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(second.state.timeline.position, held);
    expect(first.state.status, YlPlaybackStatus.paused);
    debugPrint('YL_MEMORY_PHASE=foreground');
    await stateWhere(
      second,
      (s) =>
          s.status == YlPlaybackStatus.playing &&
          s.timeline.position > held + const Duration(milliseconds: 500),
    );
    expect(first.state.sessionId, old.id);
    expect(first.state.status, YlPlaybackStatus.paused);
    expect(second.state.sessionId, active.id);
    final observations = (await probe.invokeListMethod<Object?>(
      'read',
    ))!.cast<Map>();
    debugPrint('YL_MEMORY_OUTPUT events=${jsonEncode(observations)}');
    expect(observations.any((event) => event['kind'] == 'decoder'), isTrue);
    expect(
      observations.any(
        (event) =>
            event['kind'] == 'frame' &&
            event['sessionId'] == active.id.value &&
            event['decoderSeen'] == true &&
            event['public'] == true &&
            event['matchesCurrentSurface'] == true,
      ),
      isTrue,
    );
    await probe.invokeMethod('remove');
    final rebuilt = await budgets('rebuilt');
    expect(rebuilt[1]['normalBytes'], normal[1]['normalBytes']);
    expect(rebuilt[1]['targetBytes'], normal[1]['normalBytes']);
    debugPrint(
      'YL_MEMORY_REBUILT heldMs=${held.inMilliseconds} playingMs=${second.state.timeline.position.inMilliseconds}',
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    await second.stop();
    await expectLater(active.play(), failureCode(YlFailureCodes.sessionStale));
    await old.seekTo(const Duration(seconds: 4));
    await old.play();
    await stateWhere(
      first,
      (s) =>
          s.status == YlPlaybackStatus.playing &&
          s.timeline.position > const Duration(milliseconds: 4500),
    );
    expect(first.state.failure, isNull);
    expect((await budget(old))['targetBytes'], normal[0]['normalBytes']);
    debugPrint('YL_MEMORY_PHASE=survivor');
    await Future<void>.delayed(const Duration(seconds: 2));
    await first.stop();
    await stateWhere(first, (s) => s.status == YlPlaybackStatus.idle);
    await stateWhere(second, (s) => s.status == YlPlaybackStatus.idle);
    debugPrint('YL_MEMORY_PHASE=stopped');
    await Future<void>.delayed(const Duration(seconds: 3));
  });
}
