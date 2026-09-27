import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/first_frame_probe.dart';

void main() {
  test('timestamps before Load and retains early event for bound session', () {
    var now = 100;
    final probe = FirstFrameProbe(nowUs: () => now)..start();
    now = 140;
    probe.observe('old');
    now = 200;
    probe.observe('current');
    now = 500;
    probe.bind('current');
    expect(probe.fields('passed'), {
      'outcome': 'passed',
      'startedUs': 100,
      'firstPresentedUs': 200,
      'firstFrameUs': 100,
    });
  });
  test('duplicate and post-close events cannot change first observation', () {
    var now = 10;
    final probe = FirstFrameProbe(nowUs: () => now)..start();
    probe.bind('current');
    now = 30;
    probe.observe('current');
    now = 80;
    probe.observe('current');
    probe.close();
    now = 100;
    probe.observe('current');
    expect(probe.fields('passed')['firstFrameUs'], 20);
  });
  test('missing frame is null and cannot count as passed', () {
    final probe = FirstFrameProbe(nowUs: () => 10)..start();
    probe.bind('current');
    probe.observe('old');
    expect(probe.fields('timeout')['firstFrameUs'], isNull);
    expect(() => probe.fields('passed'), throwsStateError);
  });
  test('clock reversal and reusing a probe are rejected', () {
    var now = 100;
    final probe = FirstFrameProbe(nowUs: () => now)..start();
    expect(probe.start, throwsStateError);
    now = 90;
    expect(() => probe.observe('current'), throwsStateError);
  });
}
