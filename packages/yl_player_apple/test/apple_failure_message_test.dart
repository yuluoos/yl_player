import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_apple/src/apple_codec.dart';
import 'package:yl_player_apple/src/pigeon/yl_player_apple.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'support/apple_fakes.dart';

void main() {
  const hostile =
      'https://user:secret@private.test/media?token=secret Authorization: Bearer secret';
  const messages = {
    'airplay.unsupported_source':
        'AirPlay requires a supported unprotected file, HTTP source or RTMP live stream.',
    'airplay.unsupported_codec':
        'AirPlay preparation requires H.264 video and mono or stereo AAC-LC audio.',
    'airplay.unsupported_timeline':
        'The source timeline is unsupported for AirPlay preparation.',
    'airplay.resource_limit': 'AirPlay processing exceeded its resource limit.',
    'airplay.remux_failed':
        'AirPlay HLS output failed. Check the connection, source timeline and codecs.',
    'airplay.lan_unavailable':
        'AirPlay requires a reachable Wi-Fi or Ethernet IPv4 address.',
    'render.audio_engine_failed':
        'Audio output is unavailable. Check the selected audio device and reload the media to rebuild playback.',
    'container.dash_manifest_invalid':
        'The DASH manifest could not be parsed. Ask the provider for a valid UTF-8 MPD.',
    'container.dash_dynamic_unsupported':
        'Dynamic DASH manifests are not supported by this playback path. Choose a static DASH VOD source.',
    'container.dash_protection_unsupported':
        'The DASH manifest contains a protected-content declaration unsupported by this playback path. Choose a compatible source.',
    'container.dash_segment_base_unsupported':
        'DASH SegmentBase addressing is not supported by this playback path. Choose a compatible SegmentTemplate or SegmentList source.',
    'resource.dash_manifest_too_large':
        'The DASH manifest exceeds the 2 MiB input limit. Ask the provider for a smaller manifest.',

    'source.seek_failed':
        'The playback position could not be restored. Reload the source to continue.',
    'policy.video_selection_unsupported':
        'The requested video quality is unavailable for this source.',

    'network.protocol_unsupported':
        'The media transport protocol is not supported. Use a supported source protocol.',
    'network.rtmp_tls_failed':
        'The secure RTMP connection failed TLS verification or negotiation. Check the server certificate, hostname and TLS configuration.',
    'network.rtmp_handshake_failed':
        'The RTMP connection could not be established. Check the connection and server configuration, then try again.',
    'network.rtmp_stream_unavailable':
        'The RTMP stream is unavailable. Check the stream name and whether the publisher is active.',
    'container.rtmp_track_layout_changed':
        'The RTMP track configuration changed. Reload the stream to continue playback.',
    'network.rtmp_disconnected':
        'The RTMP connection was lost during playback. Check the connection and try again.',
    'network.dns_failed':
        'The media host could not be resolved. Check the network connection and source host configuration.',
    'network.http_forbidden':
        'HTTP 403: The media server refused the request. Check access credentials and request configuration.',
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
          category: entry.key == 'render.audio_engine_failed'
              ? AppleFailureCategory.render
              : AppleFailureCategory.network,
          code: entry.key,
          message: hostile,
          retryable: false,
          scope: AppleFailureScope.session,
          diagnosticId: 'native-test-1',
        );
        final failure = AppleCodec.failure(wire);
        expect(failure.message, entry.value);
        expect(failure.toString(), isNot(contains('private.test')));
        expect(failure.toString(), isNot(contains('secret')));
        expect(failure.code, entry.key);
        if (entry.key == 'render.audio_engine_failed') {
          expect(failure.category, YlFailureCategory.render);
        }
        expect(failure.retryable, isFalse);
        expect(failure.scope, YlFailureScope.session);
        expect(failure.diagnosticId, 'native-test-1');
        final state = wireState(session: 'rtmp-session-1')
          ..status = ApplePlaybackStatus.failed
          ..failure = wire;
        final decoded = AppleCodec.state(state);
        expect(decoded.sessionId, const YlPlaybackSessionId('rtmp-session-1'));
        expect(decoded.failure, failure);
        expect(AppleCodec.problem(entry.key).failure.message, entry.value);
      },
    );
  }
  test('unknown codes never promote native text or infer a known cause', () {
    for (final code in [
      'custom.unknown',
      'airplay.remux_failed.extra',
      'render.audio_engine_failed.extra',
      'network.http_forbidden.extra',
      'network.rtmp_stream_unavailable.extra',
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
