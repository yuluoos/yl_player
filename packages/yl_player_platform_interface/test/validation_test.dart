import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  test(
    'RTMP and RTMPS admit complete app/playpath and retain supplied URI',
    () {
      for (final value in [
        'rtmp://media.test/live/stream',
        'rtmps://media.test/live/stream',
        'rtmp://media.test:1935/live/nested/stream?key=a%2Fb+q',
        'rtmp://[::1]:65535/app/stream',
        'rtmp://media.test/a%2Fb/stream%3Fname?x=one+two',
      ]) {
        final uri = Uri.parse(value);
        final source = YlNetworkSource(uri);
        validateYlSource(source);
        expect(identical(source.uri, uri), isTrue);
        expect(source.uri.toString(), value);
      }
    },
  );

  test(
    'RTMP incompatible valid policies reach native assessment unchanged',
    () {
      final source = YlNetworkSource(
        Uri.parse('rtmp://media.test/live/stream'),
        intent: YlStreamIntent.onDemand,
        format: YlMediaFormat.hls,
        networkPolicy: const YlNetworkPolicy.managed(),
        request: YlHttpRequest(
          headers: {'Accept': 'video/*'},
          credentials: {'Authorization': 'Bearer secret'},
        ),
      );
      validateYlSource(source);
      validateYlLoadOptions(
        const YlLoadOptions(
          startPosition: Duration(seconds: 1),
          bufferStrategy: YlBufferStrategy.bounded(
            minDuration: Duration.zero,
            maxDuration: Duration(seconds: 1),
            maxManagedBytes: 1024,
          ),
        ),
      );
      expect(source.request.credentials, {'Authorization': 'Bearer secret'});
      expect(source.networkPolicy.kind, YlNetworkPolicyKind.managed);
    },
  );

  test(
    'RTMP rejects unsafe or incomplete serialized URIs without identities',
    () {
      for (final value in [
        'rtmp://media.test',
        'rtmp://media.test/',
        'rtmp://media.test/app',
        'rtmp://media.test/app/',
        'rtmp://media.test//stream',
        'rtmp://media.test/app/?stream',
        'rtmp://user:secret@media.test/app/stream',
        'rtmp://media.test/app/stream#',
        'rtmp://media.test/app/stream#secret',
        'rtmp://media.test:65536/app/stream',
        'rtmp://media.test/app/str%00eam',
        'rtmp://media.test/a%0App/stream',
        'rtmp://media.test/app/stream?key=%7F',
        'rtmp://media.test/app/stream?key=%C2%85',
        'rtmp://media.test/app%FF/stream%00',
        'rtmp://media.test/app/stream%FF?key=%7F',
        'rtmp://media.test/app/stream?key=%FF%C2%85',
      ]) {
        expect(
          () => validateYlSource(YlNetworkSource(Uri.parse(value))),
          throwsA(
            isA<ArgumentError>()
                .having((e) => e.invalidValue, 'rejected value', isNull)
                .having(
                  (e) => e.toString(),
                  'safe message',
                  allOf(
                    isNot(contains('media.test')),
                    isNot(contains('secret')),
                  ),
                ),
          ),
          reason: value,
        );
      }
    },
  );

  test('RTMP retains opaque percent-encoded app playpath and query bytes', () {
    for (final value in [
      'rtmp://media.test/app%FF/stream',
      'rtmp://media.test/app/stream%FF',
      'rtmp://media.test/app/stream?key=%FE',
      'rtmp://media.test/app%85/stream%C3%A9?key=%FE+%FF',
    ]) {
      final uri = Uri.parse(value);
      final source = YlNetworkSource(uri);
      validateYlSource(source);
      expect(identical(source.uri, uri), isTrue);
      expect(source.uri.toString(), value);
    }
  });

  test('RTMP validates raw serialized escapes and explicit port syntax', () {
    for (final value in [
      'rtmp://media.test/app/stream%',
      'rtmp://media.test/app/stream%2',
      'rtmp://media.test/app/stream%GG',
      'rtmp://media.test:/app/stream',
      'rtmp://media.test:+1935/app/stream',
      'rtmp://media.test:0/app/stream',
      'rtmp://@media.test/app/stream',
    ]) {
      expect(
        () => validateYlSource(YlNetworkSource(_SerializedUri(value))),
        throwsArgumentError,
      );
    }
    // Uri.parse normalizes percent case and repairs malformed escapes before
    // core validation sees them. Preserve the supplied representation only.
    final uri = Uri.parse('rtmp://media.test/app/a%2fb+q%');
    validateYlSource(YlNetworkSource(uri));
    expect(uri.toString(), 'rtmp://media.test/app/a%2Fb+q%25');
  });

  test('RTMP URI limit counts serialized UTF-8 bytes and accepts 8192', () {
    const prefix = 'rtmp://media.test/app/';
    validateYlSource(
      YlNetworkSource(Uri.parse(prefix + 'a' * (8192 - prefix.length))),
    );
    expect(
      () => validateYlSource(
        YlNetworkSource(Uri.parse(prefix + 'a' * (8193 - prefix.length))),
      ),
      throwsArgumentError,
    );
    expect(
      () => validateYlSource(
        YlNetworkSource(_SerializedUri(prefix + 'é' * 4090)),
      ),
      throwsArgumentError,
    );
  });

  test('public input validation runs in release-compatible functions', () {
    expect(
      () => validateYlSource(YlNetworkSource(Uri.parse('file:///a'))),
      throwsArgumentError,
    );
    for (final timeout in [
      Duration.zero,
      const Duration(milliseconds: -1),
      const Duration(milliseconds: 0x80000000),
    ]) {
      expect(
        () => validateYlSource(
          YlNetworkSource(
            Uri.parse('https://example.test/a'),
            networkPolicy: YlNetworkPolicy.managed(connectTimeout: timeout),
          ),
        ),
        throwsArgumentError,
      );
    }
    for (final volume in [-1.0, 2.0, double.nan, double.infinity]) {
      expect(() => validateYlVolume(volume), throwsArgumentError);
    }
    expect(
      () => validateYlPlayerOptions(
        const YlPlayerOptions(positionUpdateInterval: Duration.zero),
      ),
      throwsArgumentError,
    );
    expect(
      () => validateYlVideoConstraints(const YlVideoConstraints(maxWidth: 0)),
      throwsArgumentError,
    );
    expect(
      () => validateYlSeekPosition(const Duration(milliseconds: -1)),
      throwsArgumentError,
    );
  });
}

// Exposes raw serialization that ordinary Uri.parse may already normalize.
class _SerializedUri implements Uri {
  _SerializedUri(this.value);
  final String value;
  @override
  String toString() => value;
  @override
  String get scheme => 'rtmp';
  @override
  bool get hasAuthority => true;
  @override
  String get authority => value.substring(7).split('/').first;
  @override
  String get host => 'media.test';
  @override
  String get userInfo => '';
  @override
  int get port => 1935;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
