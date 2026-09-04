import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  const maxNativeInt = 0x7fffffff;

  group('validateYlPlayerConfiguration', () {
    test('accepts documented boundary values', () {
      expect(
        () => validateYlPlayerConfiguration(
          const YlPlayerConfiguration(
            networkPolicy: YlNetworkPolicy(
              connectTimeout: Duration(milliseconds: 1),
              readTimeout: Duration(milliseconds: maxNativeInt),
              maxRetries: 0,
              baseRetryDelay: Duration.zero,
              maxRetryDelay: Duration(milliseconds: maxNativeInt),
              maxRedirects: 20,
            ),
            minBufferDuration: Duration.zero,
            maxBufferDuration: Duration(milliseconds: maxNativeInt),
            maxBufferBytes: 1,
            positionEventInterval: Duration(milliseconds: 1),
          ),
        ),
        returnsNormally,
      );
    });

    test('rejects zero, negative, and overflowing timeouts', () {
      for (final timeout in <Duration>[
        Duration.zero,
        const Duration(milliseconds: -1),
        const Duration(milliseconds: maxNativeInt + 1),
      ]) {
        expect(
          () => validateYlPlayerConfiguration(
            YlPlayerConfiguration(
              networkPolicy: YlNetworkPolicy(connectTimeout: timeout),
            ),
          ),
          throwsArgumentError,
        );
        expect(
          () => validateYlPlayerConfiguration(
            YlPlayerConfiguration(
              networkPolicy: YlNetworkPolicy(readTimeout: timeout),
            ),
          ),
          throwsArgumentError,
        );
      }
    });

    test('rejects retry and redirect counts outside zero through twenty', () {
      for (final count in <int>[-1, 21]) {
        expect(
          () => validateYlPlayerConfiguration(
            YlPlayerConfiguration(
              networkPolicy: YlNetworkPolicy(maxRetries: count),
            ),
          ),
          throwsArgumentError,
        );
        expect(
          () => validateYlPlayerConfiguration(
            YlPlayerConfiguration(
              networkPolicy: YlNetworkPolicy(maxRedirects: count),
            ),
          ),
          throwsArgumentError,
        );
      }
    });

    test('rejects invalid retry delays and ordering', () {
      const invalidPolicies = <YlNetworkPolicy>[
        YlNetworkPolicy(baseRetryDelay: Duration(milliseconds: -1)),
        YlNetworkPolicy(maxRetryDelay: Duration(milliseconds: -1)),
        YlNetworkPolicy(
          baseRetryDelay: Duration(seconds: 2),
          maxRetryDelay: Duration(seconds: 1),
        ),
        YlNetworkPolicy(
          baseRetryDelay: Duration(milliseconds: maxNativeInt + 1),
        ),
      ];
      for (final policy in invalidPolicies) {
        expect(
          () => validateYlPlayerConfiguration(
            YlPlayerConfiguration(networkPolicy: policy),
          ),
          throwsArgumentError,
        );
      }
    });

    test('rejects invalid position interval and buffer budgets', () {
      final invalid = <YlPlayerConfiguration>[
        const YlPlayerConfiguration(positionEventInterval: Duration.zero),
        const YlPlayerConfiguration(
          positionEventInterval: Duration(milliseconds: maxNativeInt + 1),
        ),
        const YlPlayerConfiguration(
          minBufferDuration: Duration(milliseconds: -1),
        ),
        const YlPlayerConfiguration(
          maxBufferDuration: Duration(milliseconds: -1),
        ),
        const YlPlayerConfiguration(
          minBufferDuration: Duration(seconds: 2),
          maxBufferDuration: Duration(seconds: 1),
        ),
        const YlPlayerConfiguration(maxBufferBytes: 0),
        const YlPlayerConfiguration(maxBufferBytes: maxNativeInt + 1),
      ];
      for (final configuration in invalid) {
        expect(
          () => validateYlPlayerConfiguration(configuration),
          throwsArgumentError,
        );
      }
    });
  });

  test('validates seek position boundaries', () {
    expect(() => validateYlSeekPosition(Duration.zero), returnsNormally);
    expect(
      () => validateYlSeekPosition(const Duration(milliseconds: -1)),
      throwsArgumentError,
    );
  });

  test('validates finite playback speed in the supported range', () {
    expect(() => validateYlPlaybackSpeed(0.25), returnsNormally);
    expect(() => validateYlPlaybackSpeed(4), returnsNormally);
    for (final speed in <double>[double.nan, double.infinity, 0.249, 4.001]) {
      expect(() => validateYlPlaybackSpeed(speed), throwsArgumentError);
    }
  });

  test('validates finite volume in the supported range', () {
    expect(() => validateYlVolume(0), returnsNormally);
    expect(() => validateYlVolume(1), returnsNormally);
    for (final volume in <double>[
      double.nan,
      double.negativeInfinity,
      -0.001,
      1.001,
    ]) {
      expect(() => validateYlVolume(volume), throwsArgumentError);
    }
  });

  test('validates quality fields as positive native integers', () {
    expect(
      () => validateYlQualityConstraint(
        const YlQualityConstraint(
          maxWidth: 1,
          maxHeight: maxNativeInt,
          maxBitrate: 1,
        ),
      ),
      returnsNormally,
    );
    for (final value in <int>[0, maxNativeInt + 1]) {
      expect(
        () => validateYlQualityConstraint(YlQualityConstraint(maxWidth: value)),
        throwsArgumentError,
      );
      expect(
        () =>
            validateYlQualityConstraint(YlQualityConstraint(maxHeight: value)),
        throwsArgumentError,
      );
      expect(
        () =>
            validateYlQualityConstraint(YlQualityConstraint(maxBitrate: value)),
        throwsArgumentError,
      );
    }
  });
}
