import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'support/fake_player_platform.dart';

void main() {
  testWidgets('shows placeholder until a texture is available', (tester) async {
    final backend = FakePlatformPlayer();
    YlPlayerPlatform.instance = FakePlayerPlatform(backend);
    final controller = YlPlayerController();

    await tester.pumpWidget(
      MaterialApp(
        home: YlPlayerView(
          controller: controller,
          placeholder: const Text('waiting'),
        ),
      ),
    );
    expect(find.text('waiting'), findsOneWidget);

    backend.setTextureId(42);
    await tester.pump();

    expect(find.byType(Texture), findsOneWidget);
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 42);
    await tester.runAsync(controller.dispose);
  });

  testWidgets('switching controller detaches the old texture source', (
    tester,
  ) async {
    final firstBackend = FakePlatformPlayer();
    YlPlayerPlatform.instance = FakePlayerPlatform(firstBackend);
    final firstController = YlPlayerController();

    final secondBackend = FakePlatformPlayer();
    YlPlayerPlatform.instance = FakePlayerPlatform(secondBackend);
    final secondController = YlPlayerController();

    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: firstController)),
    );
    firstBackend.setTextureId(1);
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: secondController)),
    );
    secondBackend.setTextureId(2);
    firstBackend.setTextureId(99);
    await tester.pump();

    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 2);
    await tester.runAsync(firstController.dispose);
    await tester.runAsync(secondController.dispose);
  });
}
