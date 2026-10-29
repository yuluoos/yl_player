import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';

const strictNetwork = YlNetworkPolicy.managed(
  connectTimeout: Duration(seconds: 3),
  readTimeout: Duration(seconds: 3),
  maxRetries: 1,
  baseRetryDelay: Duration(milliseconds: 100),
  maxRetryDelay: Duration(milliseconds: 100),
  maxRedirects: 2,
);
const strictBuffer = YlBufferStrategy.bounded(
  minDuration: Duration(milliseconds: 100),
  maxDuration: Duration(milliseconds: 2000),
  maxManagedBytes: 16 * 1024 * 1024,
);
Matcher failureCode(String code) => throwsA(
  isA<YlPlayerException>().having((e) => e.failure.code, 'failure code', code),
);
Future<YlPlayerController> appleController(
  WidgetTester tester, {
  YlAudioPolicy audioPolicy = YlAudioPolicy.appManaged,
}) async {
  final controller = await YlPlayerController.create(
    options: YlPlayerOptions(
      decoderPolicy: YlDecoderPolicy.systemDefault,
      audioPolicy: audioPolicy,
    ),
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(home: YlPlayerView(controller: controller)),
  );
  return controller;
}

Future<void> readyAndPlay(
  YlPlayerController controller,
  YlPlaybackSession session,
) async {
  // READY must remain available to a consumer that only starts playing later.
  await session.ready.timeout(const Duration(seconds: 15));
  expect(controller.state.sessionId, session.id);
  await session.play();
  await session.firstFrame.timeout(const Duration(seconds: 15));
  expect(controller.state.failure, isNull);
}

Future<YlPlayerState> stateWhere(
  YlPlayerController controller,
  bool Function(YlPlayerState) matches,
) async {
  if (matches(controller.state)) return controller.state;
  return controller.states
      .firstWhere(matches)
      .timeout(const Duration(seconds: 15));
}

/// Exercises public policy admission and seek on the product-selected route.
/// Native output tests separately verify PCM/pixels; timeline alone is not
/// evidence of audible samples or physical presentation.
Future<void> exercisePolicyPlayback(
  YlPlayerController player,
  YlMediaSource source, {
  YlLoadOptions options = const YlLoadOptions(),
}) async {
  final session = await player.load(source, options: options);
  await readyAndPlay(player, session);
  await stateWhere(
    player,
    (s) => s.timeline.position > const Duration(milliseconds: 300),
  );
  if (options.decoderPolicyOverride == YlDecoderPolicy.hardwareRequired) {
    expect(player.state.decoderMode.name, 'hardware');
  }
  await session.pause();
  await session.seekTo(const Duration(milliseconds: 1250));
  await session.play();
  await stateWhere(
    player,
    (s) => s.timeline.position > const Duration(milliseconds: 1800),
  );
  expect(player.state.failure, isNull);
  // Each policy case owns one hardware lease. A paused session still holds
  // that lease; release it before the next case prepares hardware evidence.
  await player.stop();
}
