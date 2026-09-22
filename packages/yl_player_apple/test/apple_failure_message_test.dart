import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_apple/src/apple_codec.dart';
import 'package:yl_player_apple/src/pigeon/yl_player_apple.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  const hostile =
      'https://user:secret@private.test/media?token=secret Authorization: Bearer secret';
  const messages = {
    'network.dns_failed':
        'The media host could not be resolved. Check the network connection and source host configuration.',
    'network.http_forbidden':
        'The media server refused the request. Check access credentials and request configuration.',
    'network.retry_exhausted':
        'The configured network retry attempts were exhausted. Check the connection and try again.',
    'load.cancelled': 'The operation was cancelled.',
    'container.unsupported':
        'The media container is not supported. Try a compatible version of the media.',
    'policy.unsupported':
        'The requested playback policy is unsupported. Check the playback configuration.',
  };
  for (final entry in messages.entries) {
    test(
      'known ${entry.key} gives safe guidance at native and adapter boundaries',
      () {
        final wire = AppleFailureMessage(
          category: AppleFailureCategory.network,
          code: entry.key,
          message: hostile,
          retryable: false,
          scope: AppleFailureScope.session,
          diagnosticId: 'native-test-1',
        );
        final failure = AppleCodec.failure(wire);
        expect(failure.message, entry.value);
        expect(failure.code, entry.key);
        expect(failure.retryable, isFalse);
        expect(failure.scope, YlFailureScope.session);
        expect(failure.diagnosticId, 'native-test-1');
        expect(AppleCodec.problem(entry.key).failure.message, entry.value);
      },
    );
  }
  test('unknown codes never promote native text or infer a known cause', () {
    for (final code in [
      'custom.unknown',
      'network.http_forbidden.extra',
      hostile,
    ]) {
      final failure = AppleCodec.failure(
        AppleFailureMessage(
          category: AppleFailureCategory.network,
          code: code,
          message: 'network.http_forbidden DNS failed $hostile',
          retryable: false,
          scope: AppleFailureScope.command,
          diagnosticId: 'native-test-2',
        ),
      );
      expect(failure.message, 'Playback operation failed.');
      expect(
        AppleCodec.problem(code).failure.message,
        'Playback operation failed.',
      );
    }
  });
}
