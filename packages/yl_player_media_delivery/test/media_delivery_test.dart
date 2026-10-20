import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_media_delivery/yl_player_media_delivery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const factory = MethodChannel('dev.ylplayer.media_delivery');
  const channel = MethodChannel('dev.ylplayer.media_delivery.owner1');
  const codec = StandardMessageCodec();
  final source = YlNetworkSource(
    Uri.parse('https://example.com/live.flv'),
    format: YlMediaFormat.flv,
    intent: YlStreamIntent.live,
  );
  Map<String, Object> ready(String id) => {
    'id': id,
    'uri': 'http://192.168.1.2:1234/token/index.m3u8',
    'contentType': 'application/vnd.apple.mpegurl',
    'isLive': true,
  };
  Future<void> event(String owner, String id, String status) =>
      messenger.handlePlatformMessage(
        'dev.ylplayer.media_delivery.events.$owner',
        codec.encodeMessage({
          'id': id,
          'status': status,
          if (status == 'failed')
            'failure': {
              'code': 'network.failed',
              'category': 'network',
              'message': 'secret credential',
            },
        }),
        (_) {},
      );
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(factory, (call) async {
      expect(call.method, 'create');
      return 'owner1';
    });
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => switch (call.method) {
        'admit' => true,
        'prepare' => ready((call.arguments as Map)['id'] as String),
        _ => null,
      },
    );
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(factory, null);
    messenger.setMockMethodCallHandler(channel, null);
  });
  test(
    'create owns delivery directly and serializes portable request',
    () async {
      Map? request;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'admit') {
          request = call.arguments as Map;
          return true;
        }
        if (call.method == 'prepare') {
          return ready((call.arguments as Map)['id'] as String);
        }
        return null;
      });
      final owner = await YlMediaDelivery.create();
      final lease = await owner.prepareMediaDelivery(source).result;
      expect(lease.isLive, isTrue);
      expect(request!['source'], containsPair('uri', source.uri.toString()));
      expect(
        (request!['options'] as Map)['bufferStrategy'],
        containsPair('kind', 'automatic'),
      );
      await owner.dispose();
      expect(lease.state.value.status, YlMediaDeliveryStatus.closed);
    },
  );
  test(
    'missing plugin and non Apple fail explicitly without raw details',
    () async {
      messenger.setMockMethodCallHandler(factory, null);
      await expectLater(
        YlMediaDelivery.create(),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            'policy.unsupported',
          ),
        ),
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await expectLater(
        YlMediaDelivery.create(),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            'policy.unsupported',
          ),
        ),
      );
    },
  );
  test(
    'rejected admission preserves pending work and accepted lease',
    () async {
      final delayed = Completer<Object?>();
      final started = Completer<void>();
      final releases = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'dispose') return null;
        final id = (call.arguments as Map)['id'] as String;
        if (call.method == 'release') {
          releases.add(id);
          return null;
        }
        if (id == 'd3') {
          throw PlatformException(
            code: 'policy.unsupported',
            details: {'category': 'unsupported', 'message': 'secret'},
          );
        }
        if (call.method == 'admit') return true;
        if (id == 'd2') {
          started.complete();
          return delayed.future;
        }
        return ready(id);
      });
      final owner = await YlMediaDelivery.create();
      addTearDown(owner.dispose);
      final lease = await owner.prepareMediaDelivery(source).result;
      final pending = owner.prepareMediaDelivery(source);
      await started.future;
      await expectLater(
        owner.prepareMediaDelivery(source).result,
        throwsA(
          isA<YlPlayerException>()
              .having((e) => e.failure.code, 'code', 'policy.unsupported')
              .having(
                (e) => e.failure.message,
                'safe',
                isNot(contains('secret')),
              ),
        ),
      );
      expect(releases, isNot(contains('d2')));
      expect(lease.state.value.status, YlMediaDeliveryStatus.ready);
      delayed.complete(ready('d2'));
      await pending.result;
      expect(lease.state.value.status, YlMediaDeliveryStatus.closed);
    },
  );
  test(
    'legal replacement cancels previous preparation; late success is released',
    () async {
      final delayed = Completer<Object?>();
      final started = Completer<void>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'dispose') return null;
        final id = (call.arguments as Map)['id'] as String;
        calls.add('${call.method}:$id');
        if (call.method == 'admit') return true;
        if (call.method == 'release') return null;
        if (id == 'd1') {
          started.complete();
          return delayed.future;
        }
        return ready(id);
      });
      final owner = await YlMediaDelivery.create();
      addTearDown(owner.dispose);
      final first = owner.prepareMediaDelivery(source);
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
      await started.future;
      final replacement = await owner.prepareMediaDelivery(source).result;
      await cancelled;
      expect(calls.indexOf('admit:d2'), lessThan(calls.indexOf('release:d1')));
      expect(
        calls.indexOf('release:d1'),
        lessThan(calls.indexOf('prepare:d2')),
      );
      delayed.complete(ready('d1'));
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c == 'release:d1'), hasLength(2));
      expect(replacement.state.value.status, YlMediaDeliveryStatus.ready);
    },
  );
  for (final dispose in [false, true]) {
    test(
      '${dispose ? 'dispose' : 'cancel'} during admission suppresses production',
      () async {
        final admission = Completer<Object?>();
        final calls = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return call.method == 'admit' ? admission.future : null;
        });
        final owner = await YlMediaDelivery.create();
        final pending = owner.prepareMediaDelivery(source);
        final cancelled = expectLater(
          pending.result,
          throwsA(isA<YlPlayerException>()),
        );
        if (dispose) {
          await owner.dispose();
        } else {
          await pending.cancel();
        }
        await cancelled;
        admission.complete(true);
        await Future<void>.delayed(Duration.zero);
        expect(calls, isNot(contains('prepare')));
        await owner.dispose();
        expect(calls.where((c) => c == 'dispose'), hasLength(1));
      },
    );
  }
  test('burst retains only latest queued admission', () async {
    final admission = Completer<Object?>();
    final preparation = Completer<Object?>();
    final admitted = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'dispose') return null;
      final id = (call.arguments as Map)['id'] as String;
      if (call.method == 'admit') {
        admitted.add(id);
        return id == 'd1' ? admission.future : true;
      }
      if (call.method == 'release') return null;
      return id == 'd1' ? preparation.future : ready(id);
    });
    final owner = await YlMediaDelivery.create();
    addTearDown(owner.dispose);
    final first = owner.prepareMediaDelivery(source);
    final cancelled1 = expectLater(
      first.result,
      throwsA(isA<YlPlayerException>()),
    );
    final middle = owner.prepareMediaDelivery(source);
    final cancelled2 = expectLater(
      middle.result,
      throwsA(isA<YlPlayerException>()),
    );
    final last = owner.prepareMediaDelivery(source);
    await cancelled2;
    expect(admitted, ['d1']);
    admission.complete(true);
    await last.result;
    await cancelled1;
    expect(admitted, ['d1', 'd3']);
    preparation.complete(ready('d1'));
    await Future<void>.delayed(Duration.zero);
  });
  test(
    'owners isolate terminal events and disposal; late events are ignored',
    () async {
      var created = 0;
      const second = MethodChannel('dev.ylplayer.media_delivery.owner2');
      messenger.setMockMethodCallHandler(
        factory,
        (call) async => 'owner${++created}',
      );
      messenger.setMockMethodCallHandler(
        second,
        (call) async => switch (call.method) {
          'admit' => true,
          'prepare' => ready((call.arguments as Map)['id'] as String),
          _ => null,
        },
      );
      addTearDown(() => messenger.setMockMethodCallHandler(second, null));
      final one = await YlMediaDelivery.create();
      final two = await YlMediaDelivery.create();
      final lease1 = await one.prepareMediaDelivery(source).result;
      final lease2 = await two.prepareMediaDelivery(source).result;
      await event('owner1', 'd1', 'failed');
      expect(lease1.state.value.status, YlMediaDeliveryStatus.failed);
      expect(lease1.state.value.failure!.message, isNot(contains('secret')));
      expect(lease2.state.value.status, YlMediaDeliveryStatus.ready);
      await one.dispose();
      await event('owner1', 'd1', 'failed');
      expect(lease1.state.value.status, YlMediaDeliveryStatus.closed);
      expect(lease2.state.value.status, YlMediaDeliveryStatus.ready);
      await two.dispose();
    },
  );
  for (final dispose in [false, true]) {
    test(
      '${dispose ? 'dispose' : 'cancel'} during production releases late success',
      () async {
        final delayed = Completer<Object?>();
        final started = Completer<void>();
        final releases = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'dispose') return null;
          final id = (call.arguments as Map)['id'] as String;
          if (call.method == 'admit') return true;
          if (call.method == 'release') {
            releases.add(id);
            return null;
          }
          started.complete();
          return delayed.future;
        });
        final owner = await YlMediaDelivery.create();
        final pending = owner.prepareMediaDelivery(source);
        final cancelled = expectLater(
          pending.result,
          throwsA(
            isA<YlPlayerException>().having(
              (e) => e.failure.code,
              'code',
              'load.cancelled',
            ),
          ),
        );
        await started.future;
        if (dispose) {
          await owner.dispose();
        } else {
          await pending.cancel();
        }
        await cancelled;
        delayed.complete(ready('d1'));
        await Future<void>.delayed(Duration.zero);
        expect(releases, ['d1', 'd1']);
        await owner.dispose();
      },
    );
  }
  test(
    'failed preparation preserves lease; completed cancellation does not close it',
    () async {
      final releases = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'dispose') return null;
        final id = (call.arguments as Map)['id'] as String;
        if (call.method == 'admit') return true;
        if (call.method == 'release') {
          releases.add(id);
          return null;
        }
        if (id == 'd2') {
          throw PlatformException(
            code: 'network.failed',
            details: {'category': 'network', 'message': 'private token'},
          );
        }
        return ready(id);
      });
      final owner = await YlMediaDelivery.create();
      final first = owner.prepareMediaDelivery(source);
      final lease = await first.result;
      await first.cancel();
      expect(lease.state.value.status, YlMediaDeliveryStatus.ready);
      await expectLater(
        owner.prepareMediaDelivery(source).result,
        throwsA(isA<YlPlayerException>()),
      );
      expect(lease.state.value.status, YlMediaDeliveryStatus.ready);
      await lease.dispose();
      await lease.dispose();
      expect(releases.where((id) => id == 'd1'), hasLength(1));
      await owner.dispose();
    },
  );
}
