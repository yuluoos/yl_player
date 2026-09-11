import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/range_media_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '250 ms updates keep their measured cadence and replacement session fence',
    (tester) async {
      final server = await RangeMediaServer.start(
        asset: 'assets/test_media/network_seek_h264_aac.mkv',
      );
      addTearDown(server.close);
      final controller = await YlPlayerController.create(
        options: const YlPlayerOptions(
          decoderPolicy: YlDecoderPolicy.systemDefault,
          positionUpdateInterval: Duration(milliseconds: 250),
        ),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: YlPlayerView(controller: controller)),
      );

      final source = YlNetworkSource(
        server.mediaUri,
        format: YlMediaFormat.matroska,
        networkPolicy: const YlNetworkPolicy.managed(
          connectTimeout: Duration(seconds: 3),
          readTimeout: Duration(seconds: 3),
          maxRetries: 1,
          baseRetryDelay: Duration(milliseconds: 100),
          maxRetryDelay: Duration(milliseconds: 100),
          maxRedirects: 2,
        ),
      );

      final oldSession = await controller.load(source);
      await oldSession.ready.timeout(const Duration(seconds: 20));
      await oldSession.play();
      await oldSession.firstFrame.timeout(const Duration(seconds: 20));

      var replacementCommitted = false;
      YlPlaybackSessionId? currentSessionId;
      var measuring = false;
      final stopwatch = Stopwatch();
      final completedOnStateEvent = Completer<void>();
      final violations = <String>[];
      var periodicTimelineUpdates = 0;
      String? lastTimelineKey;
      YlPlayerState? baseline;
      final capabilities = controller.capabilities;

      final subscription = controller.states.listen((state) {
        if (replacementCommitted && state.sessionId != currentSessionId) {
          violations.add(
            'stale session ${state.sessionId} arrived after $currentSessionId',
          );
        }
        if (!measuring || state.sessionId != currentSessionId) return;

        final reference = baseline!;
        if (controller.capabilities != capabilities) {
          violations.add('capabilities changed during a periodic update');
        }
        if (!listEquals(state.audioTracks, reference.audioTracks) ||
            !listEquals(state.videoTracks, reference.videoTracks)) {
          violations.add('tracks changed during a periodic update');
        }
        if (state.videoGeometry != reference.videoGeometry ||
            state.engine != reference.engine ||
            state.decoderMode != reference.decoderMode ||
            state.decoderIdentity != reference.decoderIdentity) {
          violations.add('geometry or decoder data changed during a delta');
        }
        if (state.timeline.duration != reference.timeline.duration ||
            state.timeline.isSeekable != reference.timeline.isSeekable ||
            state.timeline.isLive != reference.timeline.isLive ||
            state.timeline.dvrWindow != reference.timeline.dvrWindow) {
          violations.add('static timeline data changed during a delta');
        }

        // A semantic transition is not a periodic timeline sample. The window
        // is deliberately steady playback, so also retain it as a violation.
        if (state.status == YlPlaybackStatus.playing) {
          final key =
              '${state.timeline.position.inMicroseconds}:'
              '${state.timeline.bufferedPosition.inMicroseconds}:'
              '${state.timeline.isAtLiveEdge}:'
              '${state.timeline.liveOffset?.inMicroseconds}';
          if (key != lastTimelineKey) {
            periodicTimelineUpdates++;
            lastTimelineKey = key;
          }
        } else {
          violations.add(
            'semantic transition ${state.status.name} interrupted',
          );
        }

        if (stopwatch.elapsed >= const Duration(seconds: 5) &&
            !completedOnStateEvent.isCompleted) {
          completedOnStateEvent.complete();
        }
      });
      addTearDown(subscription.cancel);

      final replacement = await controller.load(source);
      currentSessionId = replacement.id;
      replacementCommitted = true;
      expect(replacement.id, isNot(oldSession.id));
      await replacement.ready.timeout(const Duration(seconds: 20));
      await replacement.play();
      await replacement.firstFrame.timeout(const Duration(seconds: 20));
      await _stateWhere(
        controller,
        (state) =>
            state.sessionId == replacement.id &&
            state.status == YlPlaybackStatus.playing &&
            state.timeline.position >= const Duration(milliseconds: 500),
      );

      baseline = controller.state;
      lastTimelineKey =
          '${baseline.timeline.position.inMicroseconds}:'
          '${baseline.timeline.bufferedPosition.inMicroseconds}:'
          '${baseline.timeline.isAtLiveEdge}:'
          '${baseline.timeline.liveOffset?.inMicroseconds}';
      measuring = true;
      stopwatch.start();
      await completedOnStateEvent.future.timeout(const Duration(seconds: 12));
      stopwatch.stop();
      measuring = false;

      final elapsedMilliseconds = stopwatch.elapsedMilliseconds;
      final fiveSecondEquivalent =
          periodicTimelineUpdates * 5000 / elapsedMilliseconds;
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(seconds: 5)),
      );
      expect(violations, isEmpty);
      expect(fiveSecondEquivalent, inInclusiveRange(12, 28));
      // Printed output is retained by the release evidence log.
      // ignore: avoid_print
      print(
        'CADENCE_PLATFORM=${Platform.operatingSystem} '
        'ELAPSED_MS=$elapsedMilliseconds '
        'PERIODIC_UPDATES=$periodicTimelineUpdates '
        'UPDATES_PER_5S=${fiveSecondEquivalent.toStringAsFixed(2)} '
        'OLD_SESSION=${oldSession.id} NEW_SESSION=${replacement.id}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<YlPlayerState> _stateWhere(
  YlPlayerController controller,
  bool Function(YlPlayerState) predicate,
) async {
  if (predicate(controller.state)) return controller.state;
  return controller.states
      .firstWhere(predicate)
      .timeout(const Duration(seconds: 20));
}
