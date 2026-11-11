import 'dart:io';
import 'package:test/test.dart';
void main() {
  test('host must react while test is still running', () async {
    print('YL_ANDROID_LIFECYCLE_BACKGROUND_READY');
    final receipt = File(Platform.environment['PROBE_HOST_RECEIPT']!);
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!receipt.existsSync() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(receipt.existsSync(), isTrue, reason: 'host never saw the live marker');
  });
}
