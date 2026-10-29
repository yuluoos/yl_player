from pathlib import Path
p=Path('tool/test_player_v2_gate.py');s=p.read_text();i=s.index('    def test_ci_stage_is_labeled_as_a_shard')
s=s[:i]+'''    def test_android_shard_configures_fresh_checkout_before_jvm_without_apk_build(self) -> None:
        result = run_gate("--quick", "--stage", "android-unit",
                          YL_GATE_CHANGED_PATHS_OVERRIDE="pubspec.lock")
        self.assertEqual(result.returncode, 0, result.stdout)
        prepare = "WOULD_RUN_IN packages/yl_player_android/example flutter build apk --debug --config-only --no-pub"
        jvm = "WOULD_RUN_IN packages/yl_player_android/example/android ./gradlew"
        self.assertIn(prepare, result.stdout)
        self.assertLess(result.stdout.index(prepare), result.stdout.index(jvm))

'''+s[i:];p.write_text(s)
p=Path('packages/yl_player/example/test/android_callback_probe_test.dart');p.write_text('''import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_android/src/pigeon/yl_player_android.g.dart';
import '../integration_test/support/android_callback_probe.dart';

void main() {
  testWidgets('network traffic callback holds and acknowledges both arguments', (
    tester,
  ) async {
    final probe = AndroidCallbackProbe('network-ack-test');
    final release = Completer<void>();
    probe.hold = release;
    addTearDown(() {
      if (!release.isCompleted) release.complete();
      probe.close();
    });
    final reply = Completer<Object?>();
    const codec = AndroidPlayerFlutterApi.pigeonChannelCodec;
    tester.binding.channelBuffers.push(
      '${AndroidCallbackProbe.prefix}.onNetworkBytesReceived.network-ack-test',
      codec.encodeMessage(<Object?>['load-owned', 1024]),
      (data) => reply.complete(codec.decodeMessage(data)),
    );
    await tester.pump();
    expect(probe.entered.isCompleted, isTrue);
    expect(probe.received, <Object>[('load-owned', 1024)]);
    expect(reply.isCompleted, isFalse);
    release.complete();
    await tester.pump();
    expect(await reply.future, isEmpty);

    final unknownReply = Completer<Object?>();
    tester.binding.channelBuffers.push(
      '${AndroidCallbackProbe.prefix}.onNetworkBytesReceived.network-ack-test',
      codec.encodeMessage(<Object?>['load-owned', null]),
      (data) => unknownReply.complete(codec.decodeMessage(data)),
    );
    await tester.pump();
    expect(probe.received.last, ('load-owned', null));
    expect(await unknownReply.future, isEmpty);
  });
}
''')
