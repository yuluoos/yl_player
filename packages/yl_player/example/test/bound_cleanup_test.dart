import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/bound_cleanup.dart';

void main() {
  test(
    'cleanup releases later resources and reports first cleanup failure',
    () async {
      final released = <int>[];
      final first = StateError('dispose');
      await expectLater(
        releaseBoundResources([
          () async {
            released.add(1);
            throw first;
          },
          () async {
            released.add(2);
            throw StateError('unmount');
          },
          () async {
            released.add(3);
          },
        ], preserveFailure: false),
        throwsA(same(first)),
      );
      expect(released, [1, 2, 3]);
    },
  );
  test('cleanup cannot replace an existing playback failure', () async {
    var closed = false;
    await releaseBoundResources([
      () async {
        throw StateError('dispose');
      },
      () async {
        closed = true;
      },
    ], preserveFailure: true);
    expect(closed, isTrue);
  });
}
