import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  const credentials = <String>[
    '{"password": "private phrase"}',
    "{'access_token': 'private phrase'}",
    'password="private phrase"',
    "client_secret='private phrase'",
    'password=private phrase',
    'password="private phrase',
    '{"password": "private \\"phrase\\" tail"}',
    '{"password": "private\nphrase"}',
    "{'access_token': 'private\nphrase'}",
  ];

  for (final input in credentials) {
    test('credential values stay private: $input', () {
      final redacted = YlSafeDiagnostics.redact(input);
      for (final word in ['private', 'phrase', 'tail']) {
        expect(redacted, isNot(contains(word)));
      }
      expect(
        YlSafeDiagnostics.publicMessage(input),
        'Playback operation failed.',
      );
    });
  }

  test('ordinary request header values stay private in diagnostics', () {
    final redacted = YlSafeDiagnostics.redact(
      'X-Custom: private value\n'
      '  private continuation\n'
      'Referer: https://private.test/path trailing-private\n'
      'User-Agent: private client',
    );
    expect(redacted, isNot(contains('private')));
  });

  test('safe prose remains readable and output remains bounded', () {
    const message = 'Decoder initialization failed.';
    expect(YlSafeDiagnostics.redact(message), message);
    expect(YlSafeDiagnostics.publicMessage(message), message);
    expect(YlSafeDiagnostics.redact('a' * 600).length, 512);
  });
}
