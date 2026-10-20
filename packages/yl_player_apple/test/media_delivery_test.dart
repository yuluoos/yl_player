import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_apple/src/apple_media_delivery.dart';
import 'package:yl_player_apple/src/apple_player.dart';
import 'support/apple_fakes.dart';
import 'package:yl_player_apple/src/pigeon/yl_player_apple.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const suffix = 'delivery-test';
  final channel = BasicMessageChannel<Object?>(
    'dev.ylplayer.delivery.$suffix',
    ApplePlayerHostApi.pigeonChannelCodec,
  );
  final source = YlNetworkSource(
    Uri.parse('https://example.com/live.flv'),
    format: YlMediaFormat.flv,
    intent: YlStreamIntent.live,
  );
  Map<String, Object> ready(String id) => {
    'value': {
      'id': id,
      'uri': 'http://192.168.1.2:1234/token/index.m3u8',
      'contentType': 'application/vnd.apple.mpegurl',
      'isLive': true,
    },
  };
  tearDown(() => messenger.setMockDecodedMessageHandler(channel, null));

  test(
    'public rejected admission preserves pending preparation and lease',
    () async {
      final nativeChannel = BasicMessageChannel<Object?>(
        'dev.ylplayer.delivery.instance-1',
        ApplePlayerHostApi.pigeonChannelCodec,
      );
      final delayed = Completer<Object?>();
      final started = Completer<void>();
      final releases = <String>[];
      final rejection = {
        'error': AppleFailureMessage(
          category: AppleFailureCategory.unsupported,
          code: 'policy.unsupported',
          message: 'unsupported',
          retryable: false,
          scope: AppleFailureScope.command,
          diagnosticId: 'test',
        ),
      };
      messenger.setMockDecodedMessageHandler(nativeChannel, (value) async {
        final request = value! as Map;
        final id = request['id'] as String;
        if (request['method'] == 'release') {
          releases.add(id);
          return {'value': true};
        }
        if (id == 'd3') return rejection;
        if (request['method'] == 'admit') return {'value': true};
        if (id == 'd2') {
          started.complete();
          return delayed.future;
        }
        return ready(id);
      });
      final transport = FakeTransport();
      final player = await ApplePlayer.create(
        const YlPlayerOptions(),
        factory: FakeFactory(wireCreate()),
        transportForSuffix: (_) => transport,
        setupCallbacks: (_, api) => transport.callbacks = api,
      );
      addTearDown(() async {
        await player.dispose();
        messenger.setMockDecodedMessageHandler(nativeChannel, null);
      });
      final lease = await player.prepareMediaDelivery(source).result;
      final pending = player.prepareMediaDelivery(source);
      var settled = false;
      final pendingResult = pending.result.then<Object>(
        (value) {
          settled = true;
          return value;
        },
        onError: (Object error) {
          settled = true;
          return error;
        },
      );
      await started.future;
      await expectLater(
        player
            .prepareMediaDelivery(
              YlNetworkSource(
                Uri.parse('https://example.com/live.flv'),
                networkPolicy: const YlNetworkPolicy.managed(),
              ),
            )
            .result,
        throwsA(
          isA<YlPlayerException>().having(
            (error) => error.failure.code,
            'code',
            'policy.unsupported',
          ),
        ),
      );
      expect(settled, isFalse);
      expect(releases, isNot(contains('d2')));
      expect(lease.state.value.status, YlMediaDeliveryStatus.ready);
      delayed.complete(ready('d2'));
      expect(await pendingResult, isA<YlMediaDeliveryLease>());
      expect(lease.state.value.status, YlMediaDeliveryStatus.closed);
    },
  );

  test(
    'admitted replacement cancels old preparation before producing',
    () async {
      final oldReply = Completer<Object?>();
      final oldStarted = Completer<void>();
      final calls = <String>[];
      messenger.setMockDecodedMessageHandler(channel, (value) async {
        final request = value! as Map;
        final method = request['method'] as String;
        final id = request['id'] as String;
        calls.add('$method:$id');
        if (method == 'admit' || method == 'release') return {'value': true};
        if (id == 'd1') {
          oldStarted.complete();
          return oldReply.future;
        }
        return ready(id);
      });
      final owner = AppleMediaDeliveryChannel(suffix);
      addTearDown(owner.close);
      final first = owner.prepare(source);
      final cancelled = expectLater(
        first.result,
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            'load.cancelled',
          ),
        ),
      );
      await oldStarted.future;
      final replacement = await owner.prepare(source).result;
      await cancelled;
      expect(calls.indexOf('admit:d2'), lessThan(calls.indexOf('release:d1')));
      expect(
        calls.indexOf('release:d1'),
        lessThan(calls.indexOf('prepare:d2')),
      );
      oldReply.complete(ready('d1'));
      await Future<void>.delayed(Duration.zero);
      expect(replacement.state.value.status, YlMediaDeliveryStatus.ready);
      expect(calls.where((e) => e == 'release:d1'), hasLength(2));
    },
  );

  for (final closeOwner in [false, true]) {
    test(
      '${closeOwner ? 'disposal' : 'cancellation'} during admission never starts production',
      () async {
        final admission = Completer<Object?>();
        final calls = <String>[];
        messenger.setMockDecodedMessageHandler(channel, (value) async {
          final request = value! as Map;
          calls.add(request['method'] as String);
          return request['method'] == 'admit'
              ? await admission.future
              : ready(request['id'] as String);
        });
        final owner = AppleMediaDeliveryChannel(suffix);
        addTearDown(owner.close);
        final pending = owner.prepare(source);
        final cancelled = expectLater(
          pending.result,
          throwsA(isA<YlPlayerException>()),
        );
        if (closeOwner) {
          owner.close();
        } else {
          await pending.cancel();
        }
        await cancelled;
        admission.complete({'value': true});
        await Future<void>.delayed(Duration.zero);
        expect(calls, ['admit']);
      },
    );
  }

  test('admission burst keeps only the latest queued candidate', () async {
    final admission = Completer<Object?>();
    final oldReply = Completer<Object?>();
    final admitted = <String>[];
    final produced = <String>[];
    messenger.setMockDecodedMessageHandler(channel, (value) async {
      final request = value! as Map;
      final id = request['id'] as String;
      if (request['method'] == 'admit') {
        admitted.add(id);
        return id == 'd1' ? await admission.future : {'value': true};
      }
      if (request['method'] == 'release') return {'value': true};
      produced.add(id);
      return id == 'd1' ? await oldReply.future : ready(id);
    });
    final owner = AppleMediaDeliveryChannel(suffix);
    addTearDown(owner.close);
    final first = owner.prepare(source);
    final firstCancelled = expectLater(
      first.result,
      throwsA(isA<YlPlayerException>()),
    );
    final middle = owner.prepare(source);
    final middleCancelled = expectLater(
      middle.result,
      throwsA(isA<YlPlayerException>()),
    );
    final last = owner.prepare(source);
    await middleCancelled;
    expect(admitted, ['d1']);
    admission.complete({'value': true});
    final lease = await last.result;
    await firstCancelled;
    expect(admitted, ['d1', 'd3']);
    expect(produced, ['d1', 'd3']);
    expect(lease.state.value.status, YlMediaDeliveryStatus.ready);
    oldReply.complete(ready('d1'));
    await Future<void>.delayed(Duration.zero);
  });

  test('lease closes once and releases only its resource', () async {
    final releases = <String>[];
    messenger.setMockDecodedMessageHandler(channel, (value) async {
      final request = value! as Map;
      if (request['method'] == 'admit') return {'value': true};
      if (request['method'] == 'prepare') return ready(request['id'] as String);
      releases.add(request['id'] as String);
      return {'value': true};
    });
    final owner = AppleMediaDeliveryChannel(suffix);
    final lease = await owner.prepare(source).result;
    expect(lease.state.value.status, YlMediaDeliveryStatus.ready);
    expect(lease.isLive, isTrue);
    await lease.dispose();
    await lease.dispose();
    expect(lease.state.value.status, YlMediaDeliveryStatus.closed);
    expect(releases, hasLength(1));
    owner.close();
  });

  test(
    'cancel settles promptly and releases delayed successful reply',
    () async {
      final pending = Completer<Object?>();
      final methods = <String>[];
      String? id;
      messenger.setMockDecodedMessageHandler(channel, (value) async {
        final request = value! as Map;
        if (request['method'] == 'admit') return {'value': true};
        methods.add(request['method'] as String);
        id ??= request['id'] as String;
        return request['method'] == 'prepare'
            ? await pending.future
            : {'value': true};
      });
      final owner = AppleMediaDeliveryChannel(suffix);
      final preparation = owner.prepare(source);
      final failure = expectLater(
        preparation.result,
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.loadCancelled,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await preparation.cancel();
      await failure;
      pending.complete(ready(id!));
      await Future<void>.delayed(Duration.zero);
      expect(methods, contains('release'));
      owner.close();
    },
  );

  test('terminal event is observable and owner close retires leases', () async {
    String? id;
    messenger.setMockDecodedMessageHandler(channel, (value) async {
      final request = value! as Map;
      if (request['method'] == 'admit') return {'value': true};
      id = request['id'] as String;
      return request['method'] == 'prepare' ? ready(id!) : {'value': true};
    });
    final owner = AppleMediaDeliveryChannel(suffix);
    final lease = await owner.prepare(source).result;
    await messenger.handlePlatformMessage(
      'dev.ylplayer.delivery.events.$suffix',
      ApplePlayerHostApi.pigeonChannelCodec.encodeMessage({
        'id': id,
        'status': 'failed',
        'failure': AppleFailureMessage(
          category: AppleFailureCategory.network,
          code: 'network.failed',
          message: 'secret',
          retryable: false,
          scope: AppleFailureScope.command,
          diagnosticId: 'delivery-test',
        ),
      }),
      (_) {},
    );
    expect(lease.state.value.status, YlMediaDeliveryStatus.failed);
    expect(lease.state.value.failure!.message, isNot(contains('secret')));
    owner.close();
    expect(lease.state.value.status, YlMediaDeliveryStatus.closed);
  });
  test(
    'failed replacement preserves accepted lease and successful replacement closes it',
    () async {
      var count = 0;
      messenger.setMockDecodedMessageHandler(channel, (value) async {
        final request = value! as Map;
        if (request['method'] == 'admit') return {'value': true};
        if (request['method'] != 'prepare') return {'value': true};
        if (++count == 2) {
          return {
            'error': AppleFailureMessage(
              category: AppleFailureCategory.network,
              code: 'network.failed',
              message: 'private upstream',
              retryable: false,
              scope: AppleFailureScope.command,
              diagnosticId: 'test',
            ),
          };
        }
        return ready(request['id'] as String);
      });
      final owner = AppleMediaDeliveryChannel(suffix);
      final first = await owner.prepare(source).result;
      await expectLater(
        owner.prepare(source).result,
        throwsA(isA<YlPlayerException>()),
      );
      expect(first.state.value.status, YlMediaDeliveryStatus.ready);
      final next = await owner.prepare(source).result;
      expect(first.state.value.status, YlMediaDeliveryStatus.closed);
      expect(next.state.value.status, YlMediaDeliveryStatus.ready);
      owner.close();
    },
  );

  test(
    'owner disposal cancels preparation and ignores delayed success',
    () async {
      final response = Completer<Object?>();
      String? id;
      messenger.setMockDecodedMessageHandler(channel, (value) async {
        final request = value! as Map;
        if (request['method'] == 'admit') return {'value': true};
        id ??= request['id'] as String;
        return request['method'] == 'prepare'
            ? await response.future
            : {'value': true};
      });
      final owner = AppleMediaDeliveryChannel(suffix);
      final preparation = owner.prepare(source);
      final rejected = expectLater(
        preparation.result,
        throwsA(isA<YlPlayerException>()),
      );
      await Future<void>.delayed(Duration.zero);
      owner.close();
      await rejected;
      response.complete(ready(id!));
      await Future<void>.delayed(Duration.zero);
      expect(() => owner.prepare(source), throwsA(isA<YlPlayerException>()));
    },
  );
  test(
    'Apple player disposal closes accepted delivery independently of playback',
    () async {
      final nativeChannel = BasicMessageChannel<Object?>(
        'dev.ylplayer.delivery.instance-1',
        ApplePlayerHostApi.pigeonChannelCodec,
      );
      final releases = <String>[];
      messenger.setMockDecodedMessageHandler(nativeChannel, (value) async {
        final request = value! as Map;
        if (request['method'] == 'admit') return {'value': true};
        if (request['method'] == 'prepare') {
          return ready(request['id'] as String);
        }
        releases.add(request['id'] as String);
        return {'value': true};
      });
      final transport = FakeTransport();
      final player = await ApplePlayer.create(
        const YlPlayerOptions(),
        factory: FakeFactory(wireCreate()),
        transportForSuffix: (_) => transport,
        setupCallbacks: (_, api) => transport.callbacks = api,
      );
      final lease = await player.prepareMediaDelivery(source).result;
      await player.dispose();
      expect(lease.state.value.status, YlMediaDeliveryStatus.closed);
      expect(releases, hasLength(1));
      expect(transport.calls, contains('dispose'));
      messenger.setMockDecodedMessageHandler(nativeChannel, null);
    },
  );
}
