import 'package:flutter_test/flutter_test.dart' as flutter_test;

export 'package:flutter_test/flutter_test.dart' hide testWidgets;

// The standalone Simulator driver builds its own Dart entrypoint and cannot
// forward flutter test's --name filter. Ordinary/local runs register every case.
Set<String> physicalOnlyCases = const {};

void testWidgets(
  String description,
  flutter_test.WidgetTesterCallback callback, {
  flutter_test.Timeout? timeout,
}) {
  if (!physicalOnlyCases.contains(description)) {
    flutter_test.testWidgets(description, callback, timeout: timeout);
  }
}
