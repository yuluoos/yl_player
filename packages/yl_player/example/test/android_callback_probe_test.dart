import 'dart:async';
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
