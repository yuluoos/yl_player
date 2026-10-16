import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_android/src/pigeon/yl_player_android.g.dart';
import 'package:yl_player_android/src/android_codec.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'support/android_fakes.dart';

AndroidLivePlaybackStateMessage live(
  AndroidLivePlaybackMode mode, [
  int? request,
]) => AndroidLivePlaybackStateMessage(
  mode: mode,
  switchableModes: AndroidLivePlaybackMode.values,
  committedRequestId: request,
);
AndroidStateMessage snapshot(
  int revision,
  AndroidLivePlaybackMode mode, [
  int? request,
]) =>
    wireState(
        session: 's1',
        revision: revision,
        sequence: revision + 10,
        status: AndroidPlaybackStatus.paused,
      )
      ..timeline.isLive = true
      ..livePlayback = live(mode, request);
void main() {
  const low = YlLivePlaybackMode.lowLatency;
  const smooth = YlLivePlaybackMode.smoothPlayback;
  test(
    'codec rejects live mode on VOD, duplicates and invalid request IDs',
    () {
      final wire = wireState(session: 's1')
        ..livePlayback = live(AndroidLivePlaybackMode.lowLatency);
      expect(() => AndroidCodec.state(wire), throwsArgumentError);
      wire.timeline.isLive = true;
      expect(AndroidCodec.state(wire).livePlayback!.mode, low);
      wire.livePlayback!.switchableModes = [
        AndroidLivePlaybackMode.lowLatency,
        AndroidLivePlaybackMode.lowLatency,
      ];
      expect(() => AndroidCodec.state(wire), throwsArgumentError);
      wire.livePlayback = live(AndroidLivePlaybackMode.lowLatency, 0);
      expect(() => AndroidCodec.state(wire), throwsArgumentError);
    },
  );
  for (final replyFirst in [true, false]) {
    test(
      'adapter waits for committed snapshot, replyFirst=$replyFirst',
      () async {
        final t = FakeTransport();
        final p = await createFake(t);
        addTearDown(p.dispose);
        final session = (await commit(t, p)).sessionId;
        t.callbacks!.onState(
          snapshot(5, AndroidLivePlaybackMode.smoothPlayback),
        );
        final reply = Completer<AndroidLivePlaybackModeReply>();
        t.liveMode = (_) => reply.future;
        var done = false;
        final future = p
            .setLivePlaybackMode(session, low)
            .then((_) => done = true);
        await flush();
        final command = t.liveCommands.single;
        expect(command.sessionId, session.value);
        expect(command.mode, AndroidLivePlaybackMode.lowLatency);
        void ack() => reply.complete(
          AndroidLivePlaybackModeReply(
            sessionId: session.value,
            requestId: command.requestId,
            committedRevision: 6,
          ),
        );
        void publish() => t.callbacks!.onState(
          snapshot(6, AndroidLivePlaybackMode.lowLatency, command.requestId),
        );
        if (replyFirst) {
          ack();
        } else {
          publish();
        }
        await flush();
        expect(done, isFalse);
        if (replyFirst) {
          publish();
        } else {
          ack();
        }
        await future;
        expect(p.state.livePlayback!.mode, low);
        expect(p.state.status, YlPlaybackStatus.paused);
      },
    );
  }
  test('two native commits before replies retain both barriers', () async {
    final t = FakeTransport();
    final p = await createFake(t);
    addTearDown(p.dispose);
    final session = (await commit(t, p)).sessionId;
    t.callbacks!.onState(snapshot(5, AndroidLivePlaybackMode.smoothPlayback));
    final replies = <Completer<AndroidLivePlaybackModeReply>>[];
    t.liveMode = (_) {
      final c = Completer<AndroidLivePlaybackModeReply>();
      replies.add(c);
      return c.future;
    };
    final one = p.setLivePlaybackMode(session, low),
        two = p.setLivePlaybackMode(session, smooth);
    await flush();
    t.callbacks!.onState(
      snapshot(
        6,
        AndroidLivePlaybackMode.lowLatency,
        t.liveCommands[0].requestId,
      ),
    );
    t.callbacks!.onState(
      snapshot(
        7,
        AndroidLivePlaybackMode.smoothPlayback,
        t.liveCommands[1].requestId,
      ),
    );
    for (var i = 1; i >= 0; i--) {
      replies[i].complete(
        AndroidLivePlaybackModeReply(
          sessionId: session.value,
          requestId: t.liveCommands[i].requestId,
          committedRevision: 6 + i,
        ),
      );
    }
    await Future.wait([one, two]);
    expect(p.state.livePlayback!.mode, smooth);
  });
  for (final fence in ['stop', 'load', 'dispose']) {
    test(
      '$fence immediately rejects pending mode even before host reply',
      () async {
        final t = FakeTransport();
        final p = await createFake(t);
        addTearDown(p.dispose);
        final session = (await commit(t, p)).sessionId;
        t.callbacks!.onState(
          snapshot(5, AndroidLivePlaybackMode.smoothPlayback),
        );
        final reply = Completer<AndroidLivePlaybackModeReply>();
        t.liveMode = (_) => reply.future;
        final failure = expectLater(
          p.setLivePlaybackMode(session, low),
          throwsA(isA<YlPlayerException>()),
        );
        await flush();
        if (fence == 'stop') {
          await p.stop();
        }
        if (fence == 'dispose') {
          await p.dispose();
        }
        if (fence == 'load') {
          final loading = expectLater(
            p.load(source),
            throwsA(isA<YlPlayerException>()),
          );
          await flush();
          await p.stop();
          await loading;
        }
        await failure;
        reply.complete(
          AndroidLivePlaybackModeReply(
            sessionId: session.value,
            requestId: 1,
            committedRevision: 6,
          ),
        );
        await flush();
      },
    );
  }
}
