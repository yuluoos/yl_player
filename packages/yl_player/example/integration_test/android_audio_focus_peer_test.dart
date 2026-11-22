import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/android_test_support.dart';

// Run with YlAudioFocusPeerInstrumentedTest on the same API 26+ device.
// The peer owns a separate UID and never starts an Activity.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Socket peer;
  late StreamIterator<String> replies;
  late File media;
  Future<void> command(String request, String expected) async {
    peer.writeln(request);
    await peer.flush();
    expect(
      await replies.moveNext().timeout(const Duration(seconds: 8)),
      isTrue,
    );
    expect(replies.current, expected);
  }

  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp('yl-focus-');
    addTearDown(() => directory.delete(recursive: true));
    final data = await rootBundle.load(
      'assets/test_media/android_audio_only.m4a',
    );
    media = await File('${directory.path}/audio.m4a').writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    try {
      debugPrint('YL_AUDIO_FOCUS_PEER port=${server.port} token=$token');
      peer = await server.first.timeout(const Duration(seconds: 45));
    } finally {
      await server.close();
    }
    replies = StreamIterator(
      peer
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
    );
    addTearDown(() async {
      try {
        await command('close', 'closed');
      } finally {
        peer.destroy();
        await replies.cancel();
      }
    });
    expect(
      await replies.moveNext().timeout(const Duration(seconds: 5)),
      isTrue,
    );
    final hello = replies.current.split(' ');
    expect(hello.length, 3);
    expect(hello[0], token);
    expect(int.parse(hello[2]), isNot(pid));
    final status = await File('/proc/self/status').readAsString();
    final uid = int.parse(
      RegExp(r'^Uid:\s+(\d+)', multiLine: true).firstMatch(status)![1]!,
    );
    expect(int.parse(hello[1]), isNot(uid));
    debugPrint('YL_FOCUS_IDENTITIES playerUid=$uid peerUid=${hello[1]}');
  });

  for (final scenario in [
    'transient',
    'long-transient',
    'duck',
    'gain',
    'user-pause',
    'app-managed',
  ]) {
    testWidgets('Android system audio focus $scenario', (tester) async {
      final appManaged = scenario == 'app-managed';
      final player = await YlPlayerController.create(
        options: YlPlayerOptions(
          audioPolicy: appManaged
              ? YlAudioPolicy.appManaged
              : YlAudioPolicy.pluginManagedMediaPlayback,
        ),
      );
      addTearDown(player.dispose);
      final session = await player.load(YlFileSource(media.path));
      await session.ready.timeout(const Duration(seconds: 15));
      await session.play();
      Future<void> advancing(Duration from) => waitForState(
        player,
        (s) =>
            s.status == YlPlaybackStatus.playing &&
            s.timeline.position > from + const Duration(milliseconds: 400),
      );
      await advancing(Duration.zero);
      final requested = ['duck', 'gain'].contains(scenario)
          ? scenario
          : 'transient';
      final resume = ['transient', 'long-transient', 'duck'].contains(scenario);
      final before = player.state.timeline.position;
      var heldPosition = before;
      final interruptedStates = <YlPlaybackStatus>[];
      final subscription = player.states.listen(
        (s) => interruptedStates.add(s.status),
      );
      addTearDown(subscription.cancel);
      await command(requested, 'granted');
      try {
        if (appManaged) {
          await advancing(before);
          expect(interruptedStates, isNot(contains(YlPlaybackStatus.paused)));
        } else {
          await waitForState(
            player,
            (s) => s.status == YlPlaybackStatus.paused,
          );
          if (scenario == 'user-pause') await session.pause();
          heldPosition = player.state.timeline.position;
          await Future<void>.delayed(
            Duration(milliseconds: scenario == 'long-transient' ? 4100 : 800),
          );
          debugPrint(
            'YL_FOCUS_CLOCK case=$scenario pauseMs=${heldPosition.inMilliseconds} endMs=${player.state.timeline.position.inMilliseconds}',
          );
          expect(player.state.status, YlPlaybackStatus.paused);
          expect(
            (player.state.timeline.position - heldPosition).inMilliseconds
                .abs(),
            lessThan(100),
          );
        }
        debugPrint(
          'YL_FOCUS_HELD case=$scenario status=${player.state.status.name} beforeMs=${before.inMilliseconds} heldMs=${player.state.timeline.position.inMilliseconds}',
        );
      } finally {
        await command('release', 'released');
      }
      if (!resume && !appManaged) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        expect(player.state.status, YlPlaybackStatus.paused);
        expect(
          (player.state.timeline.position - heldPosition).inMilliseconds.abs(),
          lessThan(100),
        );
        debugPrint(
          'YL_FOCUS_MANUAL case=$scenario afterReleaseMs=${player.state.timeline.position.inMilliseconds} status=${player.state.status.name}',
        );
        await session.play();
      }
      await advancing(player.state.timeline.position);
      expect(player.state.sessionId, session.id);
      expect(player.state.failure, isNull);
      debugPrint(
        'YL_FOCUS_RESULT case=$scenario session=${session.id.value} afterMs=${player.state.timeline.position.inMilliseconds} automatic=${resume || appManaged}',
      );
      await player.stop();
      await waitForState(player, (s) => s.sessionId == null);
    });
  }
}
