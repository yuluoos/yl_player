import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_example/main.dart';

void main() {
  testWidgets('example handles unavailable native creation', (tester) async {
    await tester.pumpWidget(const PlayerExampleApp());
    await tester.pumpAndSettle();
    expect(find.text('yl_player API example'), findsOneWidget);
    expect(find.text('Player unavailable'), findsOneWidget);
  });
}
