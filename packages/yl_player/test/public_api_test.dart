import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';

void main() {
  test('application values are available from the application barrel', () {
    expect(
      YlNetworkSource(Uri.parse('https://example.test/a')).intent,
      YlStreamIntent.automatic,
    );
    expect(const YlPlayerOptions().audioPolicy, YlAudioPolicy.appManaged);
    expect(const YlLoadOptions().autoplay, isFalse);
    expect(const YlVideoConstraints().maxWidth, isNull);
    expect(YlHttpRequest().credentials, isEmpty);
    expect(YlPlayerState().timeline, const YlTimeline());
    expect(const YlPlaybackSessionId('s').value, 's');
    expect(
      YlPlayerCapabilities(deviceProfile: 'test').decoderEvidence,
      YlDecoderEvidence.none,
    );
    expect(
      YlSourceAssessment(
        outcome: YlSourceAssessmentOutcome.requiresInspection,
      ).rejection,
      isNull,
    );
  });
  test('platform registration does not escape the app barrel', () async {
    var root = Directory.current;
    while (!File('${root.path}/.dart_tool/package_config.json').existsSync()) {
      root = root.parent;
    }
    final configFile = File('${root.path}/.dart_tool/package_config.json');
    final config =
        jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
    for (final package in config['packages'] as List) {
      package['rootUri'] = configFile.uri
          .resolve(package['rootUri'] as String)
          .toString();
    }
    final temp = await Directory.systemTemp.createTemp('yl-public-api-');
    try {
      await Directory('${temp.path}/.dart_tool').create();
      await File(
        '${temp.path}/.dart_tool/package_config.json',
      ).writeAsString(jsonEncode(config));
      await File(
        '${temp.path}/pubspec.yaml',
      ).writeAsString('name: export_boundary\nenvironment:\n  sdk: ^3.12.0\n');
      await File('${temp.path}/probe.dart').writeAsString(
        await File(
          '${root.path}/packages/yl_player/test/fixtures/platform_api_must_not_compile.dart.txt',
        ).readAsString(),
      );
      final flutterPackage = (config['packages'] as List).firstWhere(
        (entry) => entry['name'] == 'flutter',
      );
      final dart = Directory(
        Uri.parse(flutterPackage['rootUri'] as String).toFilePath(),
      ).uri.resolve('../../bin/cache/dart-sdk/bin/dart').toFilePath();
      final result = await Process.run(dart, [
        'analyze',
        '--suppress-analytics',
        '--format=machine',
        'probe.dart',
      ], workingDirectory: temp.path);
      expect(result.exitCode, isNot(0));
      expect('${result.stdout}', contains('UNDEFINED_IDENTIFIER'));
      expect('${result.stdout}', contains('YlPlayerPlatform'));
      expect('${result.stdout}', isNot(contains('URI_DOES_NOT_EXIST')));
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
