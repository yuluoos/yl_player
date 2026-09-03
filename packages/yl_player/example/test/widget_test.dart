import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_example/main.dart';

void main() {
  testWidgets('shows the public API example and milestone warning', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const PlayerExampleApp());
    await tester.pump();

    expect(find.text('yl_player API example'), findsOneWidget);
    expect(find.textContaining('native playback backends'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    expect(find.text('Open source'), findsOneWidget);
  });
}
