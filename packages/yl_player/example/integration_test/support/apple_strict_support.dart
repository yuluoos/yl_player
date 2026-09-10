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
