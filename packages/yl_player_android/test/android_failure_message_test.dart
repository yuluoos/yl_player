import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_android/src/android_codec.dart';
import 'package:yl_player_android/src/pigeon/yl_player_android.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'support/android_fakes.dart';

void main() {
  const hostile =
      'https://user:secret@private.test/media?token=secret Authorization: Bearer secret';
  const messages = {
    'network.protocol_unsupported':
        'The media transport protocol is not supported. Use a supported source protocol.',
    'network.rtmp_handshake_failed':
        'The RTMP connection could not be established. Check the connection and server configuration, then try again.',
    'network.rtmp_stream_unavailable':
        'The RTMP stream is unavailable. Check the stream name and whether the publisher is active.',
    'network.rtmp_disconnected':
        'The RTMP connection was lost during playback. Check the connection and try again.',
    'network.dns_failed':
        'The media host could not be resolved. Check the network connection and source host configuration.',
    'network.http_forbidden':
        'HTTP 403: The media server refused the request. Check access credentials and request configuration.',
    'network.retry_exhausted':
        'The configured network retry attempts were exhausted. Check the connection and try again.',
    'load.cancelled': 'The operation was cancelled.',
    'container.rtmp_track_layout_changed':
        'The RTMP track configuration changed. Reload the stream to continue playback.',
    'container.unsupported':
        'The media container is not supported. Try a compatible version of the media.',
    'policy.unsupported':
        'The requested playback policy is unsupported. Check the playback configuration.',
  };
  for (final entry in messages.entries) {
    test(
      'known ${entry.key} gives safe guidance at native and adapter boundaries',
      () {
        final wire = AndroidFailureMessage(
          category: AndroidFailureCategory.network,
          code: entry.key,
          message: hostile,
          retryable: false,
          scope: AndroidFailureScope.session,
          diagnosticId: 'native-test-1',
        );
        final failure = AndroidCodec.failure(wire);
        expect(failure.message, entry.value);
        expect(failure.code, entry.key);
        expect(failure.retryable, isFalse);
        expect(failure.scope, YlFailureScope.session);
        expect(failure.diagnosticId, 'native-test-1');
        final state = wireState(session: 'rtmp-session-1')
          ..status = AndroidPlaybackStatus.failed
          ..failure = wire;
        final decoded = AndroidCodec.state(state);
        expect(decoded.sessionId, const YlPlaybackSessionId('rtmp-session-1'));
        expect(decoded.failure, failure);
        expect(AndroidCodec.problem(entry.key).failure.message, entry.value);
      },
    );
  }
  test('unknown codes never promote native text or infer a known cause', () {
    for (final code in [
      'custom.unknown',
      'network.http_forbidden.extra',
      'network.rtmp_stream_unavailable.extra',
      hostile,
    ]) {
      final failure = AndroidCodec.failure(
        AndroidFailureMessage(
          category: AndroidFailureCategory.network,
          code: code,
          message: 'network.http_forbidden DNS failed $hostile',
          retryable: false,
          scope: AndroidFailureScope.command,
          diagnosticId: 'native-test-2',
        ),
      );
      expect(failure.message, 'Playback operation failed.');
      expect(
        AndroidCodec.problem(code).failure.message,
        'Playback operation failed.',
      );
    }
  });
}
