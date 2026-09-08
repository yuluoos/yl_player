import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'package:yl_player_platform_interface/src/channel/channel_codec.dart';

void main() {
  test('unset video constraints omit keys rejected as native null values', () {
    expect(encodeYlVideoConstraints(const YlVideoConstraints()), isEmpty);
    expect(
      encodeYlLoadOptions(const YlLoadOptions())['videoConstraints'],
      isEmpty,
    );
    expect(encodeYlVideoConstraints(const YlVideoConstraints(maxWidth: 800)), {
      'maxWidth': 800,
    });
  });
  test('legacy decoder booleans are not hardware evidence', () {
    for (final engine in ['avPlayer', 'media3']) {
      for (final hardware in [true, false]) {
        final state = decodeYlState(
          {
            'status': 'playing',
            'engine': engine,
            'isHardwareDecoding': hardware,
          },
          sessionId: const YlPlaybackSessionId('s'),
          revision: 1,
        );
        expect(state.decoderMode, YlDecoderMode.unknown);
      }
    }
  });
  test('platform details and message never expose credentials', () {
    final failure = decodeYlPlatformException(
      PlatformException(
        code: 'bad',
        message: 'https://host.test/?key=secret',
        details: {'platformDiagnostic': 'Authorization: secret'},
      ),
    );
    expect(failure.toString(), isNot(contains('secret')));
    expect(failure.failure.diagnosticId, startsWith('legacy-'));
  });
}
