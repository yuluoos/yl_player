import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/src/v2.dart';

void main() {
  final uri = Uri.parse('https://media.test/private/live.m3u8?token=hidden');
  YlNetworkSource network(YlHttpRequest request) =>
      YlNetworkSource(uri, request: request);

  test('request snapshots preserve spelling and keep credentials separate', () {
    final headers = {'User-Agent': 'yl-test'};
    final credentials = {'X-Api-Key': 'secret'};
    final request = YlHttpRequest(headers: headers, credentials: credentials);
    final source = YlNetworkSource(
      uri,
      intent: YlStreamIntent.live,
      format: YlMediaFormat.hls,
      request: request,
    );
    headers['User-Agent'] = 'changed';
    credentials.clear();
    expect(source.request.headers, {'User-Agent': 'yl-test'});
    expect(source.request.credentials, {'X-Api-Key': 'secret'});
    expect(() => request.headers.clear(), throwsUnsupportedError);
    expect(() => request.credentials.clear(), throwsUnsupportedError);
    validateYlSource(source);
    for (final diagnostic in [source.toString(), request.toString()]) {
      for (final secret in [
        'media.test',
        'private',
        'hidden',
        'User-Agent',
        'yl-test',
        'X-Api-Key',
        'secret',
      ]) {
        expect(diagnostic, isNot(contains(secret)));
      }
    }
  });

  test('request equality ignores key casing and insertion order only', () {
    final a = YlHttpRequest(
      headers: {'Accept': 'video/*', 'X-Trace': 'abc'},
      credentials: {'Authorization': 'Bearer secret'},
    );
    final b = YlHttpRequest(
      headers: {'x-trace': 'abc', 'ACCEPT': 'video/*'},
      credentials: {'authorization': 'Bearer secret'},
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect({a, b}, hasLength(1));
    expect(
      a,
      isNot(
        YlHttpRequest(
          headers: {'Accept': 'VIDEO/*', 'X-Trace': 'abc'},
          credentials: {'Authorization': 'Bearer secret'},
        ),
      ),
    );
    expect(
      YlHttpRequest(headers: {'X-Metadata': 'v'}),
      isNot(YlHttpRequest(credentials: {'X-Metadata': 'v'})),
    );
  });

  test('rejects collisions within either map and across both maps', () {
    for (final request in [
      YlHttpRequest(headers: {'Accept': 'a', 'ACCEPT': 'a'}),
      YlHttpRequest(credentials: {'X-Key': 'a', 'x-key': 'a'}),
      YlHttpRequest(
        headers: {'X-Metadata': 'a'},
        credentials: {'x-metadata': 'a'},
      ),
    ]) {
      expect(() => validateYlSource(network(request)), throwsArgumentError);
    }
  });

  test('reserved transport headers are forbidden in both maps', () {
    for (final name in [
      'hOsT',
      'Content-Length',
      'Connection',
      'Transfer-Encoding',
      'Range',
    ]) {
      for (final request in [
        YlHttpRequest(headers: {name: 'value'}),
        YlHttpRequest(credentials: {name: 'value'}),
      ]) {
        expect(() => validateYlSource(network(request)), throwsArgumentError);
      }
    }
  });

  test('recognizable credentials must use the credential map', () {
    for (final name in [
      'Authorization',
      'Proxy-Authorization',
      'Cookie',
      'X-Api-Key',
      'X-Access-Token',
      'X-Secret',
      'X-Auth',
      'private_key',
      'client_secret',
      'access_token',
      'XApiKey',
      'XAuthToken',
      'X-Credential',
    ]) {
      expect(
        () =>
            validateYlSource(network(YlHttpRequest(headers: {name: 'opaque'}))),
        throwsArgumentError,
      );
      validateYlSource(network(YlHttpRequest(credentials: {name: 'opaque'})));
    }
    validateYlSource(network(YlHttpRequest(headers: {'Accept': 'opaque'})));
  });

  test('rejects malformed header names and unsafe values in either map', () {
    for (final pair in [
      ('', 'v'),
      ('Bad Name', 'v'),
      ('X:Bad', 'v'),
      ('X\rBad', 'v'),
      ('X\nBad', 'v'),
      ('X\tBad', 'v'),
      ('X-é', 'v'),
      ('X-Good', 'a\rb'),
      ('X-Good', 'a\nb'),
      ('X-Good', 'a\u0000b'),
      ('X-Good', 'a\u001fb'),
      ('X-Good', 'a\u007fb'),
    ]) {
      for (final request in [
        YlHttpRequest(headers: {pair.$1: pair.$2}),
        YlHttpRequest(credentials: {pair.$1: pair.$2}),
      ]) {
        expect(() => validateYlSource(network(request)), throwsArgumentError);
      }
    }
    validateYlSource(
      network(YlHttpRequest(headers: {"X-Good!#\$%&'*+-.^_`|~": 'a\tb'})),
    );
  });

  test(
    'network URIs reject unsupported schemes, missing hosts and userinfo',
    () {
      for (final value in [
        'ftp://media.test/a',
        'https:/private/a',
        '/private/a',
        'https://user:pass@media.test/private',
      ]) {
        expect(
          () => validateYlSource(YlNetworkSource(Uri.parse(value))),
          throwsArgumentError,
        );
      }
      validateYlSource(YlNetworkSource(Uri.parse('http://media.test/a')));
    },
  );

  test(
    'files require absolute valid paths and expose no path in diagnostics',
    () {
      for (final path in [
        '',
        'relative.mp4',
        'C:relative.mp4',
        r'\relative.mp4',
        '\\server',
        '\\server\\',
        '/secret\u0000.mp4',
      ]) {
        expect(() => validateYlSource(YlFileSource(path)), throwsArgumentError);
      }
      for (final path in [
        '/private/a.mp4',
        r'C:\private\a.mp4',
        'D:/private/a.mp4',
        r'\\server\share\private.mp4',
      ]) {
        final source = YlFileSource(path);
        validateYlSource(source);
        expect(source.intent, YlStreamIntent.onDemand);
        expect(source.toString(), isNot(contains('private')));
      }
    },
  );

  test('content sources require an authority and content scheme', () {
    for (final value in [
      'https://media.test/a',
      'content:/private/a',
      'content://user:pass@media/private',
    ]) {
      expect(
        () => validateYlSource(YlAndroidContentSource(Uri.parse(value))),
        throwsArgumentError,
      );
    }
    final source = YlAndroidContentSource(
      Uri.parse('content://media/private/1'),
      intent: YlStreamIntent.live,
      format: YlMediaFormat.mp4,
    );
    validateYlSource(source);
    expect(source.toString(), isNot(contains('private')));
  });

  test('sensitive validation errors carry no rejected argument', () {
    final invalid = [
      YlNetworkSource(Uri.parse('https://user:secret@private.test/a')),
      YlFileSource('private-secret.mp4'),
      network(YlHttpRequest(headers: {'Authorization': 'private-secret'})),
    ];
    for (final source in invalid) {
      expect(
        () => validateYlSource(source),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.invalidValue, 'invalidValue', isNull)
              .having(
                (e) => e.toString(),
                'safe message',
                allOf(isNot(contains('secret')), isNot(contains('private'))),
              ),
        ),
      );
    }
  });

  test('source identity includes every relevant option', () {
    final a = YlNetworkSource(
      uri,
      request: YlHttpRequest(headers: {'Accept': 'v'}),
    );
    final b = YlNetworkSource(
      uri,
      request: YlHttpRequest(headers: {'ACCEPT': 'v'}),
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    for (final different in [
      YlNetworkSource(Uri.parse('https://media.test/b')),
      YlNetworkSource(uri, intent: YlStreamIntent.live),
      YlNetworkSource(uri, format: YlMediaFormat.hls),
      YlNetworkSource(uri),
      YlNetworkSource(
        uri,
        request: a.request,
        networkPolicy: const YlNetworkPolicy.managed(),
      ),
      YlFileSource('/a'),
      YlAndroidContentSource(Uri.parse('content://media/a')),
    ]) {
      expect(a, isNot(different));
    }
    expect(const YlFileSource('/a'), const YlFileSource('/a'));
    expect(const YlFileSource('/a'), isNot(const YlFileSource('/b')));
    expect(
      const YlFileSource('/a'),
      isNot(const YlFileSource('/a', format: YlMediaFormat.mp4)),
    );
    final content = Uri.parse('content://media/a');
    expect(YlAndroidContentSource(content), YlAndroidContentSource(content));
    expect(
      YlAndroidContentSource(content),
      isNot(YlAndroidContentSource(content, intent: YlStreamIntent.live)),
    );
  });

  test(
    'default policies validate without silently requesting managed support',
    () {
      final source = YlNetworkSource(uri);
      validateYlSource(source);
      expect(source.networkPolicy.kind, YlNetworkPolicyKind.platformDefault);
      expect([
        source.networkPolicy.connectTimeout,
        source.networkPolicy.readTimeout,
        source.networkPolicy.maxRetries,
        source.networkPolicy.baseRetryDelay,
        source.networkPolicy.maxRetryDelay,
        source.networkPolicy.maxRedirects,
      ], everyElement(isNull));
      validateYlSource(
        YlNetworkSource(uri, networkPolicy: const YlNetworkPolicy.managed()),
      );
      validateYlPlayerOptions(const YlPlayerOptions());
      validateYlLoadOptions(const YlLoadOptions());
      for (final strategy in [
        const YlBufferStrategy.automatic(),
        const YlBufferStrategy.lowLatency(),
        const YlBufferStrategy.smoothPlayback(),
      ]) {
        validateYlLoadOptions(YlLoadOptions(bufferStrategy: strategy));
        expect([
          strategy.minDuration,
          strategy.maxDuration,
          strategy.maxManagedBytes,
        ], everyElement(isNull));
      }
    },
  );

  test('managed policy uses signed32 bounds and coherent retry delays', () {
    for (final policy in [
      const YlNetworkPolicy.managed(connectTimeout: Duration.zero),
      const YlNetworkPolicy.managed(readTimeout: Duration(microseconds: -1)),
      const YlNetworkPolicy.managed(
        connectTimeout: Duration(milliseconds: 2147483648),
      ),
      const YlNetworkPolicy.managed(
        readTimeout: Duration(milliseconds: 2147483648),
      ),
      const YlNetworkPolicy.managed(baseRetryDelay: Duration(microseconds: -1)),
      const YlNetworkPolicy.managed(maxRetryDelay: Duration(microseconds: -1)),
      const YlNetworkPolicy.managed(
        baseRetryDelay: Duration(milliseconds: 2147483648),
      ),
      const YlNetworkPolicy.managed(
        maxRetryDelay: Duration(milliseconds: 2147483648),
      ),
      const YlNetworkPolicy.managed(baseRetryDelay: Duration(seconds: 9)),
      const YlNetworkPolicy.managed(maxRetries: -1),
      const YlNetworkPolicy.managed(maxRetries: 2147483648),
      const YlNetworkPolicy.managed(maxRedirects: -1),
      const YlNetworkPolicy.managed(maxRedirects: 2147483648),
    ]) {
      expect(
        () => validateYlSource(YlNetworkSource(uri, networkPolicy: policy)),
        throwsArgumentError,
      );
    }
    validateYlSource(
      YlNetworkSource(
        uri,
        networkPolicy: const YlNetworkPolicy.managed(
          connectTimeout: Duration(milliseconds: 2147483647),
          readTimeout: Duration(milliseconds: 1),
          maxRetries: 2147483647,
          baseRetryDelay: Duration.zero,
          maxRetryDelay: Duration(milliseconds: 2147483647),
          maxRedirects: 0,
        ),
      ),
    );
  });

  test(
    'bounded buffers require ordered nonnegative durations and positive budget',
    () {
      for (final strategy in [
        const YlBufferStrategy.bounded(
          minDuration: Duration(seconds: 2),
          maxDuration: Duration(seconds: 1),
          maxManagedBytes: 1024,
        ),
        const YlBufferStrategy.bounded(
          minDuration: Duration(microseconds: -1),
          maxDuration: Duration(seconds: 1),
          maxManagedBytes: 1024,
        ),
        const YlBufferStrategy.bounded(
          minDuration: Duration.zero,
          maxDuration: Duration(microseconds: -1),
          maxManagedBytes: 1024,
        ),
        const YlBufferStrategy.bounded(
          minDuration: Duration.zero,
          maxDuration: Duration(milliseconds: 2147483648),
          maxManagedBytes: 1024,
        ),
        const YlBufferStrategy.bounded(
          minDuration: Duration.zero,
          maxDuration: Duration(seconds: 1),
          maxManagedBytes: 0,
        ),
        const YlBufferStrategy.bounded(
          minDuration: Duration.zero,
          maxDuration: Duration(seconds: 1),
          maxManagedBytes: 2147483648,
        ),
      ]) {
        expect(
          () => validateYlLoadOptions(YlLoadOptions(bufferStrategy: strategy)),
          throwsArgumentError,
        );
      }
      validateYlLoadOptions(
        const YlLoadOptions(
          bufferStrategy: YlBufferStrategy.bounded(
            minDuration: Duration.zero,
            maxDuration: Duration(milliseconds: 2147483647),
            maxManagedBytes: 2147483647,
          ),
        ),
      );
    },
  );

  test(
    'video constraints validate for load and runtime and can clear limits',
    () {
      const original = YlVideoConstraints(
        maxWidth: 1920,
        maxHeight: 1080,
        maxBitrate: 8000000,
      );
      expect(original.copyWith(), original);
      expect(original.copyWith().hashCode, original.hashCode);
      expect(
        original.copyWith(maxWidth: 1280, maxHeight: null),
        const YlVideoConstraints(maxWidth: 1280, maxBitrate: 8000000),
      );
      expect(
        original.copyWith(maxWidth: null, maxHeight: null, maxBitrate: null),
        const YlVideoConstraints(),
      );
      for (final value in [-1, 0, 2147483648]) {
        for (final constraints in [
          YlVideoConstraints(maxWidth: value),
          YlVideoConstraints(maxHeight: value),
          YlVideoConstraints(maxBitrate: value),
        ]) {
          expect(
            () => validateYlVideoConstraints(constraints),
            throwsArgumentError,
          );
          expect(
            () => validateYlLoadOptions(
              YlLoadOptions(videoConstraints: constraints),
            ),
            throwsArgumentError,
          );
        }
      }
      validateYlVideoConstraints(
        const YlVideoConstraints(
          maxWidth: 1,
          maxHeight: 2147483647,
          maxBitrate: 2147483647,
        ),
      );
    },
  );

  test(
    'constraint copyWith rejects noninteger and nonfinite inputs safely',
    () {
      const constraints = YlVideoConstraints(maxWidth: 1920);
      for (final value in [
        double.nan,
        double.infinity,
        1.5,
        'private-secret',
      ]) {
        for (final update in [
          () => constraints.copyWith(maxWidth: value),
          () => constraints.copyWith(maxHeight: value),
          () => constraints.copyWith(maxBitrate: value),
        ]) {
          expect(
            update,
            throwsA(
              isA<ArgumentError>()
                  .having((e) => e.invalidValue, 'invalid value', isNull)
                  .having(
                    (e) => e.toString(),
                    'safe error',
                    isNot(contains('private-secret')),
                  ),
            ),
          );
        }
      }
    },
  );

  test('exact policy durations cannot be truncated to whole milliseconds', () {
    for (final duration in [
      const Duration(microseconds: 1500),
      const Duration(microseconds: 2147483647001),
    ]) {
      for (final policy in [
        YlNetworkPolicy.managed(connectTimeout: duration),
        YlNetworkPolicy.managed(readTimeout: duration),
        YlNetworkPolicy.managed(
          baseRetryDelay: duration,
          maxRetryDelay: duration,
        ),
        YlNetworkPolicy.managed(maxRetryDelay: duration),
      ]) {
        expect(
          () => validateYlSource(YlNetworkSource(uri, networkPolicy: policy)),
          throwsArgumentError,
        );
      }
      expect(
        () => validateYlPlayerOptions(
          YlPlayerOptions(positionUpdateInterval: duration),
        ),
        throwsArgumentError,
      );
      expect(
        () => validateYlLoadOptions(
          YlLoadOptions(
            bufferStrategy: YlBufferStrategy.bounded(
              minDuration: duration,
              maxDuration: duration,
              maxManagedBytes: 1,
            ),
          ),
        ),
        throwsArgumentError,
      );
    }
  });

  test('player sampling interval must fit positive native milliseconds', () {
    for (final interval in [
      Duration.zero,
      const Duration(microseconds: -1),
      const Duration(microseconds: 1),
      const Duration(milliseconds: 2147483648),
    ]) {
      expect(
        () => validateYlPlayerOptions(
          YlPlayerOptions(positionUpdateInterval: interval),
        ),
        throwsArgumentError,
      );
    }
    validateYlPlayerOptions(
      const YlPlayerOptions(
        positionUpdateInterval: Duration(milliseconds: 2147483647),
      ),
    );
  });

  test(
    'timeline allows long media positions but rejects negative submilliseconds',
    () {
      for (final position in [
        Duration.zero,
        const Duration(milliseconds: 2147483648),
        const Duration(microseconds: 9223372036854775807),
      ]) {
        validateYlSeekPosition(position);
        validateYlLoadOptions(YlLoadOptions(startPosition: position));
      }
      for (final position in [
        const Duration(microseconds: -1),
        const Duration(seconds: -1),
      ]) {
        expect(() => validateYlSeekPosition(position), throwsArgumentError);
        expect(
          () => validateYlLoadOptions(YlLoadOptions(startPosition: position)),
          throwsArgumentError,
        );
      }
    },
  );

  test('volume and speed reject nonfinite and out of range controls', () {
    for (final value in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
      -0.01,
      1.01,
    ]) {
      expect(() => validateYlVolume(value), throwsArgumentError);
    }
    for (final value in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
      0.2499,
      4.0001,
    ]) {
      expect(() => validateYlPlaybackSpeed(value), throwsArgumentError);
    }
    for (final value in [0.0, 0.5, 1.0]) {
      validateYlVolume(value);
    }
    for (final value in [0.25, 1.0, 4.0]) {
      validateYlPlaybackSpeed(value);
    }
  });

  test(
    'track ids are opaque nonempty values and errors do not expose them',
    () {
      validateYlTrackId('opaque/private?id=secret');
      expect(() => validateYlTrackId(''), throwsArgumentError);
    },
  );

  test(
    'policy and option values compare structurally with matching hashes',
    () {
      final equalValues = <(Object, Object)>[
        (
          YlNetworkPolicy.platformDefault(),
          const YlNetworkPolicy.platformDefault(),
        ),
        (YlNetworkPolicy.managed(), const YlNetworkPolicy.managed()),
        (YlBufferStrategy.automatic(), const YlBufferStrategy.automatic()),
        (YlBufferStrategy.lowLatency(), const YlBufferStrategy.lowLatency()),
        (
          YlBufferStrategy.smoothPlayback(),
          const YlBufferStrategy.smoothPlayback(),
        ),
        (
          YlBufferStrategy.bounded(
            minDuration: Duration.zero,
            maxDuration: const Duration(seconds: 1),
            maxManagedBytes: 1024,
          ),
          const YlBufferStrategy.bounded(
            minDuration: Duration.zero,
            maxDuration: Duration(seconds: 1),
            maxManagedBytes: 1024,
          ),
        ),
        (YlPlayerOptions(), const YlPlayerOptions()),
        (
          YlLoadOptions(
            videoConstraints: const YlVideoConstraints(maxWidth: 1920),
          ),
          const YlLoadOptions(
            videoConstraints: YlVideoConstraints(maxWidth: 1920),
          ),
        ),
        (YlFileSource('/a'), const YlFileSource('/a')),
      ];
      for (final (left, right) in equalValues) {
        expect(identical(left, right), isFalse);
        expect(left, right);
        expect(left.hashCode, right.hashCode);
        expect({left, right}, hasLength(1));
      }
      for (final changed in [
        const YlNetworkPolicy.platformDefault(),
        const YlNetworkPolicy.managed(connectTimeout: Duration(seconds: 1)),
        const YlNetworkPolicy.managed(readTimeout: Duration(seconds: 1)),
        const YlNetworkPolicy.managed(maxRetries: 1),
        const YlNetworkPolicy.managed(baseRetryDelay: Duration.zero),
        const YlNetworkPolicy.managed(maxRetryDelay: Duration(seconds: 1)),
        const YlNetworkPolicy.managed(maxRedirects: 1),
      ]) {
        expect(YlNetworkPolicy.managed(), isNot(changed));
      }
      for (final changed in [
        const YlPlayerOptions(
          audioPolicy: YlAudioPolicy.pluginManagedMediaPlayback,
        ),
        const YlPlayerOptions(decoderPolicy: YlDecoderPolicy.hardwareRequired),
        const YlPlayerOptions(positionUpdateInterval: Duration(seconds: 1)),
      ]) {
        expect(YlPlayerOptions(), isNot(changed));
      }
      for (final changed in [
        const YlLoadOptions(autoplay: true),
        const YlLoadOptions(startPosition: Duration.zero),
        const YlLoadOptions(bufferStrategy: YlBufferStrategy.lowLatency()),
        const YlLoadOptions(
          videoConstraints: YlVideoConstraints(maxWidth: 1920),
        ),
        const YlLoadOptions(
          decoderPolicyOverride: YlDecoderPolicy.hardwareRequired,
        ),
      ]) {
        expect(YlLoadOptions(), isNot(changed));
      }
    },
  );
}
