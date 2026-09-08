import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  test('session ids and failures use structural equality', () {
    const a = YlPlaybackSessionId('native-7');
    const b = YlPlaybackSessionId('native-7');
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    final runtimeA = YlPlaybackSessionId('native-7');
    final runtimeB = YlPlaybackSessionId('native-7');
    expect(identical(runtimeA, runtimeB), isFalse);
    expect(runtimeA, runtimeB);

    const first = YlFailure(
      category: YlFailureCategory.network,
      code: YlFailureCodes.networkFailed,
      message: 'Playback request failed.',
      retryable: true,
      scope: YlFailureScope.session,
      diagnosticId: 'diag-42',
    );
    const equal = YlFailure(
      category: YlFailureCategory.network,
      code: YlFailureCodes.networkFailed,
      message: 'Playback request failed.',
      retryable: true,
      scope: YlFailureScope.session,
      diagnosticId: 'diag-42',
    );

    expect(first, equal);
    expect(first.hashCode, equal.hashCode);
    final runtimeFirst = YlFailure(
      category: YlFailureCategory.network,
      code: YlFailureCodes.networkFailed,
      message: 'Playback request failed.',
      retryable: true,
      scope: YlFailureScope.session,
      diagnosticId: 'diag-42',
    );
    final runtimeEqual = YlFailure(
      category: YlFailureCategory.network,
      code: YlFailureCodes.networkFailed,
      message: 'Playback request failed.',
      retryable: true,
      scope: YlFailureScope.session,
      diagnosticId: 'diag-42',
    );
    expect(identical(runtimeFirst, runtimeEqual), isFalse);
    expect(runtimeFirst, runtimeEqual);
    expect(runtimeFirst.hashCode, runtimeEqual.hashCode);
    expect(<YlFailure>[
      const YlFailure(
        category: YlFailureCategory.internal,
        code: YlFailureCodes.networkFailed,
        message: 'Playback request failed.',
        retryable: true,
        scope: YlFailureScope.session,
        diagnosticId: 'diag-42',
      ),
      const YlFailure(
        category: YlFailureCategory.network,
        code: YlFailureCodes.internal,
        message: 'Playback request failed.',
        retryable: true,
        scope: YlFailureScope.session,
        diagnosticId: 'diag-42',
      ),
      const YlFailure(
        category: YlFailureCategory.network,
        code: YlFailureCodes.networkFailed,
        message: 'Different message.',
        retryable: true,
        scope: YlFailureScope.session,
        diagnosticId: 'diag-42',
      ),
      const YlFailure(
        category: YlFailureCategory.network,
        code: YlFailureCodes.networkFailed,
        message: 'Playback request failed.',
        retryable: false,
        scope: YlFailureScope.session,
        diagnosticId: 'diag-42',
      ),
      const YlFailure(
        category: YlFailureCategory.network,
        code: YlFailureCodes.networkFailed,
        message: 'Playback request failed.',
        retryable: true,
        scope: YlFailureScope.player,
        diagnosticId: 'diag-42',
      ),
      const YlFailure(
        category: YlFailureCategory.network,
        code: YlFailureCodes.networkFailed,
        message: 'Playback request failed.',
        retryable: true,
        scope: YlFailureScope.session,
        diagnosticId: 'diag-43',
      ),
    ], everyElement(isNot(first)));
  });

  test('session ids have a redacted string and release validation', () {
    const id = YlPlaybackSessionId('native-secret-session');
    expect(id.toString(), 'YlPlaybackSessionId(<redacted>)');
    expect(() => validateYlPlaybackSessionId(id), returnsNormally);
    expect(
      () => validateYlPlaybackSessionId(const YlPlaybackSessionId('')),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          'Playback session ID must not be empty.',
        ),
      ),
    );
  });

  test('public strings never expose sensitive input', () {
    const secret = 'https://user:pass@example.test/a.m3u8?token=secret';
    final failure = YlFailure(
      category: YlFailureCategory.internal,
      code: YlFailureCodes.internal,
      message: YlSafeDiagnostics.publicMessage(secret),
      retryable: false,
      scope: YlFailureScope.player,
      diagnosticId: 'diag-1',
    );
    final text = <String>[
      failure.toString(),
      YlPlayerException(failure).toString(),
      const YlPlaybackSessionId(secret).toString(),
    ].join(' ');
    expect(text, isNot(contains('secret')));
    expect(text, isNot(contains('user:pass')));
    expect(text, isNot(contains('example.test')));
  });

  test('failure strings expose only safe failure metadata', () {
    const failure = YlFailure(
      category: YlFailureCategory.network,
      code: YlFailureCodes.networkFailed,
      message: 'private playback message',
      retryable: true,
      scope: YlFailureScope.session,
      diagnosticId: 'diag-42',
    );
    final text = failure.toString();

    expect(text, contains(YlFailureCategory.network.name));
    expect(text, contains(YlFailureCodes.networkFailed));
    expect(text, contains('retryable: true'));
    expect(text, contains(YlFailureScope.session.name));
    expect(text, contains('diag-42'));
    expect(text, isNot(contains(failure.message)));
    expect(YlPlayerException(failure).toString(), text);
  });

  test('failure strings redact hostile code and diagnostic identifiers', () {
    const failure = YlFailure(
      category: YlFailureCategory.internal,
      code: 'https://code.test/failure?token=code-secret',
      message: 'Cookie: sid=message-secret',
      retryable: false,
      scope: YlFailureScope.player,
      diagnosticId:
          'Authorization: Bearer diag-secret /Users/alice/private/key.txt',
    );
    final text = <String>[
      failure.toString(),
      YlPlayerException(failure).toString(),
    ].join(' ');

    for (final sensitive in <String>[
      'code.test',
      'code-secret',
      'message-secret',
      'diag-secret',
      '/Users/alice',
      'key.txt',
    ]) {
      expect(text, isNot(contains(sensitive)), reason: sensitive);
    }
  });

  test('credential assignments never reach diagnostics or failure strings', () {
    const assignments =
        'client_secret=private access_token=abc private_key=value';
    const failure = YlFailure(
      category: YlFailureCategory.internal,
      code: 'client_secret=private',
      message: 'Playback request failed.',
      retryable: false,
      scope: YlFailureScope.player,
      diagnosticId: 'access_token=abc private_key=value',
    );
    final text = <String>[
      YlSafeDiagnostics.redact(assignments),
      failure.toString(),
      YlPlayerException(failure).toString(),
    ].join(' ');

    for (final sensitive in <String>[
      'client_secret',
      'private',
      'access_token',
      'abc',
      'private_key',
      'value',
    ]) {
      expect(text, isNot(contains(sensitive)), reason: sensitive);
    }
  });

  test('failure strings hide ordinary structured metadata fields', () {
    const failure = YlFailure(
      category: YlFailureCategory.internal,
      code: 'X_Custom: private-code',
      message: 'Playback request failed.',
      retryable: false,
      scope: YlFailureScope.player,
      diagnosticId: 'X-Trace: private-diagnostic',
    );
    final text = <String>[
      failure.toString(),
      YlPlayerException(failure).toString(),
    ].join(' ');

    for (final sensitive in <String>[
      'X_Custom',
      'private-code',
      'X-Trace',
      'private-diagnostic',
    ]) {
      expect(text, isNot(contains(sensitive)), reason: sensitive);
    }
  });

  test('redaction removes URL, query, header, and bearer shapes', () {
    final redacted = YlSafeDiagnostics.redact(
      'GET https://media.test/a?token=abc '
      'Authorization: Bearer xyz Cookie: sid=123 X-Api-Key: value',
    );
    expect(redacted, isNot(contains('media.test')));
    expect(redacted, isNot(contains('abc')));
    expect(redacted, isNot(contains('xyz')));
    expect(redacted, isNot(contains('123')));
    expect(redacted, isNot(contains('value')));
  });

  test('redaction handles case-insensitive sensitive headers', () {
    final redacted = YlSafeDiagnostics.redact(
      'authorization: Basic alpha\n'
      'PROXY-AUTHORIZATION: Bearer bravo\n'
      'cookie: charlie\n'
      'SET-COOKIE: delta\n'
      'X-Access-Token: echo\n'
      'x-client-key: foxtrot\n'
      'X-Secret-Value: golf\n'
      'X-Credential: hotel\n'
      'X-Custom-Auth: india\n'
      'X_API_KEY: juliett',
    );

    for (final sensitive in <String>[
      'alpha',
      'bravo',
      'charlie',
      'delta',
      'echo',
      'foxtrot',
      'golf',
      'hotel',
      'india',
      'juliett',
    ]) {
      expect(redacted, isNot(contains(sensitive)), reason: sensitive);
    }
  });

  test('redaction handles sensitive headers without optional whitespace', () {
    final redacted = YlSafeDiagnostics.redact(
      'Authorization:Bearer xyz\nCookie:sid=123 other=456',
    );

    expect(redacted, '<redacted-header> <redacted-header>');
  });

  test('HTTP token header names share detection and redaction grammar', () {
    expect(
      YlSafeDiagnostics.publicMessage('X_Custom: private-value'),
      'Playback operation failed.',
    );
    final redacted = YlSafeDiagnostics.redact('X.Auth.Value: private-value');
    expect(redacted, isNot(contains('X.Auth.Value')));
    expect(redacted, isNot(contains('private-value')));
  });

  test('generic URI schemes are replaced before path redaction', () {
    expect(
      YlSafeDiagnostics.redact(
        'custom-media://user:pass@host.test/a?token=secret',
      ),
      '<redacted-uri>',
    );
  });

  test('generic URI schemes without authority are fully replaced', () {
    expect(
      YlSafeDiagnostics.redact(
        'mailto:alice@example.test urn:credential:private '
        'data:text/plain,private',
      ),
      '<redacted-uri> <redacted-uri> <redacted-uri>',
    );
  });

  test('redaction removes file paths and standalone query fragments', () {
    final redacted = YlSafeDiagnostics.redact(
      'failed at /Users/alice/private/media.m3u8?token=path-secret '
      r'and C:\Users\alice\private\media.mp4?api_key=windows-secret',
    );

    expect(redacted, isNot(contains('/Users/alice')));
    expect(redacted, isNot(contains(r'C:\Users\alice')));
    expect(redacted, isNot(contains('path-secret')));
    expect(redacted, isNot(contains('windows-secret')));
  });

  test('public messages replace unsafe diagnostic shapes', () {
    const unsafeInputs = <String>[
      'https://media.test/a.m3u8',
      'Authorization: Bearer token-value',
      'Bearer token-value',
      'line one\nline two',
      '#0 Player.open (package:yl_player/player.dart:12:4)',
      '/Users/alice/private/media.m3u8',
    ];

    for (final input in unsafeInputs) {
      expect(
        YlSafeDiagnostics.publicMessage(input),
        'Playback operation failed.',
        reason: input,
      );
    }
    expect(
      YlSafeDiagnostics.publicMessage('Decoder initialization failed.'),
      'Decoder initialization failed.',
    );
  });

  test('redacted diagnostics are capped after sensitive data is removed', () {
    final redacted = YlSafeDiagnostics.redact(
      '${'a' * 600} https://media.test/a?token=tail-secret',
    );

    expect(redacted.length, 512);
    expect(redacted, isNot(contains('media.test')));
    expect(redacted, isNot(contains('tail-secret')));
  });
}
