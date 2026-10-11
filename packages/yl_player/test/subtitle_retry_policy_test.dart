import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_resource_io.dart';
import 'package:yl_player/yl_player.dart';

void main() {
  final now = DateTime.utc(2026, 10, 11, 12);
  const policy = YlNetworkPolicy.managed(
    baseRetryDelay: Duration(milliseconds: 500),
    maxRetryDelay: Duration(seconds: 8),
  );
  test('exponential delay saturates without overflow or count-sized work', () {
    for (final (index, ms) in [
      (1, 500),
      (2, 1000),
      (5, 8000),
      (2147483647, 8000),
    ]) {
      expect(
        subtitleRetryDelay(policy, index, null, now),
        Duration(milliseconds: ms),
      );
    }
    expect(
      subtitleRetryDelay(
        const YlNetworkPolicy.managed(baseRetryDelay: Duration.zero),
        2147483647,
        null,
        now,
      ),
      Duration.zero,
    );
    expect(
      subtitleRetryDelay(
        const YlNetworkPolicy.managed(maxRetryDelay: Duration.zero),
        1,
        null,
        now,
      ),
      Duration.zero,
    );
  });
  test(
    'valid Retry-After seconds override and excessive values forbid retry',
    () {
      expect(subtitleRetryDelay(policy, 1, '0', now), Duration.zero);
      expect(
        subtitleRetryDelay(policy, 1, ' 2 ', now),
        const Duration(seconds: 2),
      );
      expect(
        subtitleRetryDelay(policy, 1, '0008', now),
        const Duration(seconds: 8),
      );
      expect(subtitleRetryDelay(policy, 1, '9', now), isNull);
      expect(subtitleRetryDelay(policy, 1, '9' * 100, now), isNull);
    },
  );
  test('dates use injected wall time and past values mean zero delay', () {
    expect(
      subtitleRetryDelay(policy, 1, 'Sun, 11 Oct 2026 12:00:05 GMT', now),
      const Duration(seconds: 5),
    );
    expect(
      subtitleRetryDelay(policy, 1, 'Sun, 11 Oct 2026 11:59:59 GMT', now),
      Duration.zero,
    );
    expect(
      subtitleRetryDelay(policy, 1, 'Sun, 11 Oct 2026 12:00:09 GMT', now),
      isNull,
    );
  });
  test('malformed values fall back to exponential delay', () {
    for (final value in ['', 'bad', '-1', '1.5', '+2', '2 seconds']) {
      expect(
        subtitleRetryDelay(policy, 2, value, now),
        const Duration(seconds: 1),
      );
    }
  });
  test(
    'obsolete HTTP dates resolve two-digit years against injected clock',
    () {
      expect(
        subtitleRetryDelay(policy, 1, 'Sunday, 11-Oct-26 12:00:05 GMT', now),
        const Duration(seconds: 5),
      );
      expect(
        subtitleRetryDelay(policy, 1, 'Sun Oct 11 12:00:05 2026', now),
        const Duration(seconds: 5),
      );
    },
  );
  test('obsolete date window also crosses a century boundary', () {
    expect(
      subtitleRetryDelay(
        policy,
        1,
        'Sunday, 11-Oct-26 12:00:05 GMT',
        DateTime.utc(2090, 10, 11, 12),
      ),
      isNull,
    );
  });
  test(
    'invalid calendar dates and truncated fields fall back rather than normalize',
    () {
      for (final value in [
        'Sun, 32 Oct 2026 12:00:05 GMT',
        'Sun, 11 Oct 2026 25:00:00 GMT',
        'Sun, 00 Oct 2026 12:00:05 GMT',
        'Sun, 11 Oct 2026 12:70:00 GMT',
        'Sun Oct',
      ]) {
        expect(
          subtitleRetryDelay(policy, 1, value, now),
          const Duration(milliseconds: 500),
        );
      }
    },
  );
}
