import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/network_traffic.dart';

void main() {
  test(
    'samples real elapsed time, idle zero and resets without spikes',
    () async {
      var micros = 0;
      final source = StreamController<int?>.broadcast(sync: true);
      final sampler = NetworkTrafficSampler(
        source.stream,
        nowMicroseconds: () => micros,
      );
      final rates = <int?>[];
      expect(source.hasListener, isFalse);
      final subscription = sampler.rates.listen(rates.add);
      await Future<void>.delayed(Duration.zero);
      expect(rates.last, isNull);
      source.add(0);
      source.add(4096);
      micros = 2000000;
      await sampler.rates.skip(1).first;
      expect(
        rates.last,
        2048,
        reason: 'Use elapsed time, not the timer interval',
      );
      micros = 3000000;
      await sampler.rates.skip(1).first;
      expect(rates.last, 0);
      source.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(rates.last, isNull);
      source.add(0);
      source.add(1024);
      micros = 4000000;
      await sampler.rates.skip(1).first;
      expect(rates.last, 1024);
      source.add(1);
      micros = 5000000;
      await sampler.rates.skip(1).first;
      expect(rates.last, 0, reason: 'Counter rollover resets the baseline');
      await subscription.cancel();
      expect(source.hasListener, isFalse);
      await sampler.dispose();
      await source.close();
    },
  );

  test(
    'on-demand resubscription ignores historical bytes and disposal closes',
    () async {
      var micros = 0;
      final source = StreamController<int?>.broadcast(sync: true);
      final sampler = NetworkTrafficSampler(
        source.stream,
        nowMicroseconds: () => micros,
      );
      final first = sampler.rates.listen((_) {});
      source.add(0);
      await first.cancel();
      final rates = <int?>[];
      var done = false;
      sampler.rates.listen(rates.add, onDone: () => done = true);
      source.add(50000);
      micros = 1000000;
      await sampler.rates.skip(1).first;
      expect(rates.last, 0);
      source.add(51024);
      micros = 2000000;
      await sampler.rates.skip(1).first;
      expect(rates.last, 1024);
      await sampler.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(done, isTrue);
      expect(source.hasListener, isFalse);
      await source.close();
    },
  );
}
