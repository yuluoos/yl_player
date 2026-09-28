import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_apple/src/apple_drm.dart';
import 'package:yl_player_apple/src/pigeon/yl_player_apple.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  final source = YlNetworkSource(
    Uri.parse('https://media.test/a.m3u8'),
    format: YlMediaFormat.hls,
    drm: YlFairPlayDrm(
      certificate: YlDrmBytes([1]),
      contentId: YlDrmBytes([2]),
      license: YlDrmLicenseEndpoint(Uri.parse('https://license.test')),
    ),
  );
  AppleDrmLicenseRequest request({
    String load = 'l1',
    int player = 1,
    String exchange = 'key1',
  }) => AppleDrmLicenseRequest(
    id: AppleDrmExchangeId(
      surface: AppleProtectedSurfaceMessage(
        playerId: player,
        surfaceId: 2,
        sessionId: 's1',
        generation: 3,
      ),
      loadRequestId: load,
      epoch: 1,
      requestId: 1,
      exchangeId: exchange,
    ),
    challenge: Uint8List.fromList([7]),
  );
  test('newer frame before delayed attach ACK remains ready', () async {
    final host = _RetryHost();
    final bridge = AppleDrmChannel(
      'test',
      AppleDrmSupportMessage(
        contractVersion: 1,
        playerId: 1,
        platform: ApplePlatform.ios,
        schemeAvailable: true,
      ),
      host: host,
    );
    bridge.exchange = (_, _, _) async => YlDrmBytes([8]);
    bridge.begin('l1', source);
    final wire = request().id.surface;
    bridge.checkReply('l1', 's1', wire);
    bridge.commit('l1');
    final attaching = bridge.attach(bridge.surface!, 10);
    bridge.onProtectedFrame(
      AppleProtectedViewAck(
        surface: wire,
        viewId: 10,
        revision: 2,
        attached: true,
      ),
    );
    host.attempts.single.complete(
      AppleProtectedViewAck(
        surface: wire,
        viewId: 10,
        revision: 1,
        attached: true,
      ),
    );
    await attaching;
    expect(bridge.frameReady('s1'), isTrue);
    bridge.close();
  });
  test(
    'older frame feedback cannot withdraw a newer acknowledged frame',
    () async {
      final host = _RetryHost();
      final bridge = AppleDrmChannel(
        'test',
        AppleDrmSupportMessage(
          contractVersion: 1,
          playerId: 1,
          platform: ApplePlatform.macos,
          schemeAvailable: true,
        ),
        host: host,
      );
      bridge.exchange = (_, _, _) async => YlDrmBytes([8]);
      bridge.begin('l1', source);
      final wire = request().id.surface;
      bridge.checkReply('l1', 's1', wire);
      bridge.commit('l1');
      final attaching = bridge.attach(bridge.surface!, 10);
      host.attempts.single.complete(
        AppleProtectedViewAck(
          surface: wire,
          viewId: 10,
          revision: 1,
          attached: true,
        ),
      );
      await attaching;
      bridge.onProtectedFrame(
        AppleProtectedViewAck(
          surface: wire,
          viewId: 10,
          revision: 2,
          attached: true,
        ),
      );
      expect(bridge.frameReady('s1'), isTrue);
      bridge.onProtectedFrame(
        AppleProtectedViewAck(
          surface: wire,
          viewId: 10,
          revision: 1,
          attached: true,
        ),
      );
      expect(bridge.frameReady('s1'), isTrue);
      bridge.close();
    },
  );
  for (final unmount in [false, true]) {
    for (final timeout in [false, true]) {
      testWidgets(
        'stale attach ${unmount ? "unmount" : "replacement"} ${timeout ? "timeout" : "failure"} is ignored',
        (tester) async {
          final host = _HeldHost();
          final bridge = AppleDrmChannel(
            'test',
            AppleDrmSupportMessage(
              contractVersion: 1,
              playerId: 1,
              platform: ApplePlatform.ios,
              schemeAvailable: true,
            ),
            host: host,
          );
          bridge.exchange = (_, _, _) async => YlDrmBytes([8]);
          bridge.begin('l1', source);
          bridge.checkReply('l1', 's1', request().id.surface);
          bridge.commit('l1');
          final surface = bridge.surface!;
          Object? error;
          var completed = false;
          final attaching = bridge
              .attach(surface, 10)
              .then(
                (_) {
                  completed = true;
                },
                onError: (Object e) {
                  error = e;
                },
              );
          await tester.pump();
          if (unmount) {
            await bridge.detach(surface, 10);
          } else {
            bridge.commit('clear-session');
          }
          if (timeout) {
            await tester.pump(const Duration(seconds: 6));
          } else {
            host.attached.completeError(
              PlatformException(code: 'session.stale'),
            );
            await tester.pump();
          }
          await attaching;
          expect(error, isNull);
          expect(completed, isTrue);
          bridge.close();
        },
      );
    }
  }
  testWidgets(
    'same view retry fences previous success and failure but current failure is published',
    (tester) async {
      final host = _RetryHost();
      final bridge = AppleDrmChannel(
        'test',
        AppleDrmSupportMessage(
          contractVersion: 1,
          playerId: 1,
          platform: ApplePlatform.ios,
          schemeAvailable: true,
        ),
        host: host,
      );
      bridge.exchange = (_, _, _) async => YlDrmBytes([8]);
      bridge.begin('l1', source);
      final wire = request().id.surface;
      bridge.checkReply('l1', 's1', wire);
      bridge.commit('l1');
      final surface = bridge.surface!;
      final failures = <Object>[];
      final first = bridge.attach(surface, 10, onFailure: failures.add);
      final second = bridge.attach(surface, 10, onFailure: failures.add);
      final third = bridge.attach(surface, 10, onFailure: failures.add);
      host.attempts[0].complete(
        AppleProtectedViewAck(
          surface: wire,
          viewId: 10,
          revision: 1,
          attached: true,
        ),
      );
      host.attempts[1].completeError(PlatformException(code: 'session.stale'));
      await first;
      await second;
      bridge.onProtectedFrame(
        AppleProtectedViewAck(
          surface: wire,
          viewId: 10,
          revision: 1,
          attached: true,
        ),
      );
      expect(bridge.frameReady('s1'), isFalse);
      expect(failures, isEmpty);
      final assertion = expectLater(third, throwsA(isA<YlPlayerException>()));
      await tester.pump(const Duration(seconds: 6));
      await assertion;
      expect(failures, hasLength(1));
      expect(
        (failures.single as YlPlayerException).failure.code,
        YlFailureCodes.drmProtectionInsufficient,
      );
      bridge.close();
    },
  );
  test(
    'wrong owner and duplicate challenge never issue another license POST',
    () async {
      var posts = 0;
      final bridge = AppleDrmChannel(
        'test',
        AppleDrmSupportMessage(
          contractVersion: 1,
          playerId: 1,
          platform: ApplePlatform.ios,
          schemeAvailable: true,
        ),
      );
      bridge.exchange = (endpoint, challenge, cancelled) async {
        posts++;
        return YlDrmBytes([8]);
      };
      bridge.begin('l1', source);
      expect(
        (await bridge.exchangeLicense(request(player: 9))).failureCode,
        YlFailureCodes.loadCancelled,
      );
      expect((await bridge.exchangeLicense(request())).response, [8]);
      expect(
        (await bridge.exchangeLicense(request())).failureCode,
        YlFailureCodes.loadCancelled,
      );
      expect(posts, 1);
      bridge.close();
    },
  );
  test('cancel fences a late non-cancellable license response', () async {
    final response = Completer<YlDrmBytes>();
    final bridge = AppleDrmChannel(
      'test',
      AppleDrmSupportMessage(
        contractVersion: 1,
        playerId: 1,
        platform: ApplePlatform.ios,
        schemeAvailable: true,
      ),
    );
    bridge.exchange = (_, _, _) => response.future;
    bridge.begin('l1', source);
    final reply = bridge.exchangeLicense(request());
    bridge.cancel('l1');
    expect((await reply).failureCode, YlFailureCodes.loadCancelled);
    response.complete(YlDrmBytes([8]));
    await Future<void>.delayed(Duration.zero);
    expect(bridge.surface, isNull);
    bridge.close();
  });
}

class _HeldHost extends AppleDrmHostApi {
  final attached = Completer<AppleProtectedViewAck>();
  @override
  Future<AppleProtectedViewAck> attachProtectedView(
    AppleProtectedViewCommand command,
  ) => attached.future;
  @override
  Future<AppleProtectedViewAck> detachProtectedView(
    AppleProtectedViewCommand command,
  ) async => AppleProtectedViewAck(
    surface: command.surface,
    viewId: command.viewId,
    revision: 2,
    attached: false,
  );
  @override
  Future<void> cancelProtectedLoad(String loadRequestId) async {}
}

class _RetryHost extends _HeldHost {
  final attempts = <Completer<AppleProtectedViewAck>>[];
  @override
  Future<AppleProtectedViewAck> attachProtectedView(
    AppleProtectedViewCommand command,
  ) {
    final attempt = Completer<AppleProtectedViewAck>();
    attempts.add(attempt);
    return attempt.future;
  }
}
