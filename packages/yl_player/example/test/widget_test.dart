import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_example/main.dart';

import '../../test/support/fake_player_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlatformPlayer backend;
  late FakePlayerPlatform platform;

  setUp(() {
    backend = FakePlatformPlayer();
    platform = FakePlayerPlatform(backend);
  });

  testWidgets('example handles unavailable native creation', (tester) async {
    platform.createError = StateError('private native creation details');

    await tester.pumpWidget(_app(platform));
    await tester.pumpAndSettle();

    expect(find.text('yl_player API example'), findsOneWidget);
    expect(find.text('Player unavailable'), findsOneWidget);
  });

  testWidgets('Pause observes errors without displaying raw exception text', (
    tester,
  ) async {
    await _pumpLoadedPlayer(
      tester,
      platform,
      const YlPlaybackSessionId('pause'),
    );
    backend.commandError = StateError(
      'Authorization: secret at https://private.example/media',
    );

    await _tapButton(tester, 'Pause');

    expect(find.text('Could not pause playback.'), findsOneWidget);
    expect(find.textContaining('private.example'), findsNothing);
  });

  testWidgets('rejected Stop reports safe failure and preserves the session', (
    tester,
  ) async {
    const id = YlPlaybackSessionId('stop-rejected');
    await _pumpLoadedPlayer(tester, platform, id);
    backend.stopError = _safeFailure;

    await _tapButton(tester, 'Stop');

    expect(find.text('Playback operation failed.'), findsOneWidget);
    backend.stopError = null;
    await _tapButton(tester, 'Pause');
    expect(backend.lastCommand, ('pause', id));
  });

  testWidgets('accepted Stop clears the session handle', (tester) async {
    await _pumpLoadedPlayer(
      tester,
      platform,
      const YlPlaybackSessionId('stop-accepted'),
    );

    await _tapButton(tester, 'Stop');
    expect(find.text('Stopped'), findsOneWidget);

    final pauseCount = backend.calls.where((call) => call == 'pause').length;
    await _tapButton(tester, 'Pause');
    expect(backend.calls.where((call) => call == 'pause').length, pauseCount);
    expect(tester.takeException(), isNull);
  });

  testWidgets('obsolete work cannot replace newer UI or command authority', (
    tester,
  ) async {
    const oldId = YlPlaybackSessionId('old');
    const newId = YlPlaybackSessionId('new');
    await tester.pumpWidget(_app(platform));
    await tester.pumpAndSettle();
    await _enterUrl(tester);

    await _tapButton(tester, 'Load and play');
    backend.delayCommand('play', oldId);
    backend.commit(oldId);
    await tester.pump();

    await _tapButton(tester, 'Load and play');
    backend.commit(newId, index: 1);
    await tester.pump();
    backend.emit(status: YlPlaybackStatus.ready);
    await tester.pump();
    backend.emitFirstFrame(newId);
    await tester.pump();
    expect(find.text('First frame displayed'), findsOneWidget);

    backend.completeCommand('play', oldId);
    await tester.pump();
    expect(find.text('First frame displayed'), findsOneWidget);

    await _tapButton(tester, 'Pause');
    expect(backend.lastCommand, ('pause', newId));
  });

  testWidgets('widget disposal safely settles pending load and cleanup', (
    tester,
  ) async {
    await tester.pumpWidget(_app(platform));
    await tester.pumpAndSettle();
    await _enterUrl(tester);
    await _tapButton(tester, 'Load and play');

    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    backend.commit(const YlPlaybackSessionId('disposed-load'));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpLoadedPlayer(
  WidgetTester tester,
  FakePlayerPlatform platform,
  YlPlaybackSessionId id,
) async {
  await tester.pumpWidget(_app(platform));
  await tester.pumpAndSettle();
  await _enterUrl(tester);
  await _tapButton(tester, 'Load and play');
  platform.backend.commit(id);
  await tester.pump();
  platform.backend.emit(status: YlPlaybackStatus.ready);
  await tester.pump();
  platform.backend.emitFirstFrame(id);
  await tester.pump();
  expect(find.text('First frame displayed'), findsOneWidget);
}

Future<void> _enterUrl(WidgetTester tester) =>
    tester.enterText(find.byType(TextField), 'https://example.test/video.mp4');

PlayerExampleApp _app(FakePlayerPlatform platform) => PlayerExampleApp(
  createPlayer: () => YlPlayerController.create(platform: platform),
);

Future<void> _tapButton(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.scrollUntilVisible(
    finder,
    160,
    scrollable: find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.tap(finder);
  await tester.pump();
}

const _safeFailure = YlPlayerException(
  YlFailure(
    category: YlFailureCategory.network,
    code: YlFailureCodes.networkFailed,
    message: 'Playback operation failed.',
    retryable: true,
    scope: YlFailureScope.command,
    diagnosticId: 'example-safe-failure',
  ),
);
