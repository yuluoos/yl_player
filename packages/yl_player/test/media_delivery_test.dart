import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'support/fake_player_platform.dart';

void main() {
  final source = YlNetworkSource(
    Uri.parse('rtmp://example.com/live/stream'),
    intent: YlStreamIntent.live,
  );
  test(
    'unsupported delivery does not replace pending local playback',
    () async {
      final backend = FakePlatformPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      expect(player.supportsMediaDelivery, isFalse);
      final local = player.load(source);
      expect(
        () => player.prepareMediaDelivery(source),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.policyUnsupported,
          ),
        ),
      );
      backend.commit(const YlPlaybackSessionId('local'));
      expect((await local).id, const YlPlaybackSessionId('local'));
      expect(backend.loads, hasLength(1));
      await player.dispose();
    },
  );
  test('delivery forwards the cancellable SPI without local load', () async {
    final backend = _DeliveryBackend();
    final player = await YlPlayerController.create(
      platform: FakePlayerPlatform(backend),
    );
    expect(player.supportsMediaDelivery, isTrue);
    const options = YlLoadOptions(
      bufferStrategy: YlBufferStrategy.smoothPlayback(),
    );
    final preparation = player.prepareMediaDelivery(source, options: options);
    expect(identical(preparation, backend.preparation), isTrue);
    expect(backend.source, source);
    expect(backend.options, options);
    expect(backend.loads, isEmpty);
    await preparation.cancel();
    expect(backend.preparation.cancelled, isTrue);
    await player.dispose();
    expect(
      () => player.prepareMediaDelivery(source),
      throwsA(
        isA<YlPlayerException>().having(
          (e) => e.failure.code,
          'code',
          YlFailureCodes.playerDisposed,
        ),
      ),
    );
  });
}

class _DeliveryBackend extends FakePlatformPlayer
    implements YlMediaDeliveryPlatformPlayer {
  final preparation = _Preparation();
  YlMediaSource? source;
  YlLoadOptions? options;
  @override
  YlMediaDeliveryPreparation prepareMediaDelivery(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) {
    this.source = source;
    this.options = options;
    return preparation;
  }
}

class _Preparation implements YlMediaDeliveryPreparation {
  bool cancelled = false;
  @override
  final result = Completer<YlMediaDeliveryLease>().future;
  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}
