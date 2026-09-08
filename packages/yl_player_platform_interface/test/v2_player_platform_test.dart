import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  final original = YlPlayerPlatform.instance;
  tearDown(() => YlPlayerPlatform.instance = original);

  test(
    'unregistered v2 platform returns a typed unavailable failure',
    () async {
      await expectLater(
        original.createPlayer(const YlPlayerOptions()),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.platformUnavailable,
          ),
        ),
      );
    },
  );
  test('registration accepts token subclasses and explicit platform mocks', () {
    final platform = _Platform();
    YlPlayerPlatform.instance = platform;
    expect(YlPlayerPlatform.instance, same(platform));
    final mock = _MockPlatform();
    YlPlayerPlatform.instance = mock;
    expect(YlPlayerPlatform.instance, same(mock));
  });
  test('registration rejects a foreign implements-only platform', () {
    expect(
      () => YlPlayerPlatform.instance = _ForeignPlatform(),
      throwsAssertionError,
    );
    expect(YlPlayerPlatform.instance, same(original));
  });
  test(
    'implementation and load identities compare structurally and redact metadata',
    () {
      const info = YlPlatformImplementationInfo(
        name: 'secret/path',
        version: 'token=secret',
        spiMajor: ylPlayerSpiMajor,
      );
      const equal = YlPlatformImplementationInfo(
        name: 'secret/path',
        version: 'token=secret',
        spiMajor: 2,
      );
      expect(info, equal);
      expect(info.hashCode, equal.hashCode);
      expect(info.toString(), isNot(contains('secret')));
      const load = YlPlatformLoadResult(
        sessionId: YlPlaybackSessionId('secret'),
      );
      const sameLoad = YlPlatformLoadResult(
        sessionId: YlPlaybackSessionId('secret'),
      );
      expect(load, sameLoad);
      expect(load.hashCode, sameLoad.hashCode);
      expect(load.toString(), isNot(contains('secret')));
    },
  );
}

class _Platform extends YlPlayerPlatform {
  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerOptions options) =>
      throw UnimplementedError();
}

class _MockPlatform
    with MockPlatformInterfaceMixin
    implements YlPlayerPlatform {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ForeignPlatform implements YlPlayerPlatform {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
