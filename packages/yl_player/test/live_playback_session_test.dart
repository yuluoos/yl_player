import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'support/fake_player_platform.dart';

const sid = YlPlaybackSessionId('live-1');
final media = YlNetworkSource(Uri.parse('https://example.test/live'));
Matcher failure(String code) => throwsA(
  isA<YlPlayerException>()
      .having((e) => e.failure.code, 'code', code)
      .having((e) => e.failure.scope, 'scope', YlFailureScope.command),
);

class AdvertisedBackend extends FakePlatformPlayer {
  AdvertisedBackend({this.advertise = true});
  final bool advertise;
  @override
  YlPlayerCapabilities get capabilities => YlPlayerCapabilities(
    deviceProfile: 'live-test',
    supportedOperations: advertise ? [YlPlayerOperation.livePlaybackMode] : [],
  );
}

class LiveBackend extends AdvertisedBackend
    implements YlLivePlaybackPlatformPlayer {
  LiveBackend({super.advertise});
  final requests =
      <(YlPlaybackSessionId, YlLivePlaybackMode, Completer<void>)>[];
  @override
  Future<void> setLivePlaybackMode(
    YlPlaybackSessionId id,
    YlLivePlaybackMode mode,
  ) {
    final ack = Completer<void>();
    requests.add((id, mode, ack));
    return ack.future;
  }
}

Future<(YlPlayerController, YlPlaybackSession)> load(
  FakePlatformPlayer backend, {
  bool isLive = true,
  bool known = true,
  List<YlLivePlaybackMode>? modes,
}) async {
  final player = await YlPlayerController.create(
    platform: FakePlayerPlatform(backend),
  );
  final future = player.load(media);
  backend.commit(sid);
  backend.emitState(
    backend.state.copyWith(
      status: YlPlaybackStatus.paused,
      revision: backend.state.revision + 1,
      timeline: YlTimeline(isLive: isLive),
      livePlayback: known && isLive
          ? YlLivePlaybackState(
              mode: YlLivePlaybackMode.smoothPlayback,
              switchableModes: modes ?? YlLivePlaybackMode.values,
            )
          : null,
    ),
  );
  return (player, await future);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final entry in <String, FakePlatformPlayer Function()>{
    'legacy': FakePlatformPlayer.new,
    'operation without SPI': AdvertisedBackend.new,
    'SPI without operation': () => LiveBackend(advertise: false),
  }.entries) {
    test('rejects ${entry.key} before backend dispatch', () async {
      final backend = entry.value();
      final (player, session) = await load(backend);
      addTearDown(player.dispose);
      await expectLater(
        session.setLivePlaybackMode(YlLivePlaybackMode.lowLatency),
        failure(YlFailureCodes.policyUnsupported),
      );
      if (backend is LiveBackend) expect(backend.requests, isEmpty);
    });
  }
  for (final scenario in [
    'vod',
    'unknown',
    'unsupported',
    'same-mode-unsupported',
  ]) {
    test('session admission rejects $scenario without dispatch', () async {
      final backend = LiveBackend();
      final (player, session) = await load(
        backend,
        isLive: scenario != 'vod',
        known: scenario != 'unknown',
        modes: [],
      );
      addTearDown(player.dispose);
      await expectLater(
        session.setLivePlaybackMode(
          scenario == 'same-mode-unsupported'
              ? YlLivePlaybackMode.smoothPlayback
              : YlLivePlaybackMode.lowLatency,
        ),
        failure(YlFailureCodes.policyUnsupported),
      );
      expect(backend.requests, isEmpty);
    });
  }
  test(
    'awaits backend commit without optimistic state or changing pause intent',
    () async {
      final backend = LiveBackend();
      final (player, session) = await load(backend);
      addTearDown(player.dispose);
      final before = player.state;
      var done = false;
      final future = session
          .setLivePlaybackMode(YlLivePlaybackMode.lowLatency)
          .then((_) => done = true);
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      expect(player.state, before);
      expect(backend.requests.single.$1, sid);
      expect(backend.requests.single.$2, YlLivePlaybackMode.lowLatency);
      backend.emitState(
        backend.state.copyWith(
          revision: backend.state.revision + 1,
          livePlayback: YlLivePlaybackState(
            mode: YlLivePlaybackMode.lowLatency,
            switchableModes: YlLivePlaybackMode.values,
          ),
        ),
      );
      backend.requests.single.$3.complete();
      await future;
      expect(player.state.livePlayback!.mode, YlLivePlaybackMode.lowLatency);
      expect(player.state.status, YlPlaybackStatus.paused);
    },
  );
  test(
    'current rejection preserves state and releases pending admission',
    () async {
      final backend = LiveBackend();
      final (player, session) = await load(backend);
      addTearDown(player.dispose);
      final before = player.state;
      final error = StateError('backend rejection');
      final future = session.setLivePlaybackMode(YlLivePlaybackMode.lowLatency);
      final check = expectLater(future, throwsA(same(error)));
      backend.requests.single.$3.completeError(error);
      await check;
      expect(player.state, before);
      final retry = session.setLivePlaybackMode(
        YlLivePlaybackMode.smoothPlayback,
      );
      backend.requests.last.$3.complete();
      await retry;
    },
  );
  test(
    '32 unsettled commands are bounded and a settled slot is reusable',
    () async {
      final backend = LiveBackend();
      final (player, session) = await load(backend);
      addTearDown(player.dispose);
      final pending = List.generate(
        32,
        (_) => session.setLivePlaybackMode(YlLivePlaybackMode.lowLatency),
      );
      await expectLater(
        session.setLivePlaybackMode(YlLivePlaybackMode.lowLatency),
        throwsA(
          isA<YlPlayerException>()
              .having(
                (e) => e.failure.code,
                'code',
                YlFailureCodes.resourceExhausted,
              )
              .having(
                (e) => e.failure.category,
                'category',
                YlFailureCategory.resource,
              ),
        ),
      );
      expect(backend.requests, hasLength(32));
      backend.requests.first.$3.complete();
      await pending.first;
      final retry = session.setLivePlaybackMode(
        YlLivePlaybackMode.smoothPlayback,
      );
      expect(backend.requests, hasLength(33));
      for (final request in backend.requests.skip(1)) {
        request.$3.complete();
      }
      await Future.wait([...pending, retry]);
    },
  );
  for (final action in ['replace', 'stop', 'dispose']) {
    for (final reject in [false, true]) {
      test(
        'late ${reject ? 'error' : 'ACK'} after $action cannot succeed on new session',
        () async {
          final backend = LiveBackend();
          final (player, session) = await load(backend);
          addTearDown(player.dispose);
          final future = session.setLivePlaybackMode(
            YlLivePlaybackMode.lowLatency,
          );
          final check = expectLater(
            future,
            failure(
              action == 'dispose'
                  ? YlFailureCodes.playerDisposed
                  : YlFailureCodes.sessionStale,
            ),
          );
          if (action == 'replace') {
            final next = player.load(media);
            backend.commit(const YlPlaybackSessionId('live-2'));
            await next;
          } else if (action == 'stop') {
            await player.stop();
          } else {
            await player.dispose();
          }
          final afterLifecycle = player.state;
          if (reject) {
            backend.requests.single.$3.completeError(StateError('old error'));
          } else {
            backend.requests.single.$3.complete();
          }
          await check;
          expect(player.state, afterLifecycle);
          if (action != 'dispose') expect(player.state.livePlayback, isNull);
          await expectLater(
            session.setLivePlaybackMode(YlLivePlaybackMode.lowLatency),
            failure(
              action == 'dispose'
                  ? YlFailureCodes.playerDisposed
                  : YlFailureCodes.sessionStale,
            ),
          );
          expect(backend.requests, hasLength(1));
        },
      );
    }
  }
  for (final reject in [false, true]) {
    test(
      'same-session stream failure preserves ${reject ? 'rejection' : 'committed ACK'}',
      () async {
        final backend = LiveBackend();
        final (player, session) = await load(backend);
        addTearDown(player.dispose);
        const failureValue = YlFailure(
          category: YlFailureCategory.network,
          code: YlFailureCodes.networkFailed,
          message: 'Stream failed.',
          retryable: true,
          scope: YlFailureScope.session,
          diagnosticId: 'live-terminal',
        );
        const rejection = YlPlayerException(failureValue);
        final pending = session.setLivePlaybackMode(
          YlLivePlaybackMode.lowLatency,
        );
        final assertion = reject
            ? expectLater(pending, throwsA(same(rejection)))
            : expectLater(pending, completes);
        backend.emitState(
          backend.state.copyWith(
            revision: backend.state.revision + 1,
            status: YlPlaybackStatus.failed,
            failure: failureValue,
          ),
        );
        if (reject) {
          backend.requests.single.$3.completeError(rejection);
        } else {
          backend.requests.single.$3.complete();
        }
        await assertion;
        expect(player.state.failure, failureValue);
        await expectLater(
          session.setLivePlaybackMode(YlLivePlaybackMode.lowLatency),
          failure(YlFailureCodes.sessionStale),
        );
        expect(backend.requests, hasLength(1));
      },
    );
  }
}
