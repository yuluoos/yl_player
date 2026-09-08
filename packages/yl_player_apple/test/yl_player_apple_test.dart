import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_apple/yl_player_apple.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  final repository = _findRepositoryRoot();
  final package = Directory('${repository.path}/packages/yl_player_apple');

  test(
    'registration installs an implementation that rejects player creation',
    () async {
      final previous = YlPlayerPlatform.instance;
      addTearDown(() => YlPlayerPlatform.instance = previous);

      YlPlayerApple.registerWith();

      expect(YlPlayerPlatform.instance, isA<YlPlayerApple>());
      await expectLater(
        YlPlayerPlatform.instance.createPlayer(const YlPlayerOptions()),
        throwsA(
          isA<YlPlayerException>()
              .having(
                (error) => error.failure.category,
                'category',
                YlFailureCategory.platform,
              )
              .having(
                (error) => error.failure.code,
                'code',
                YlFailureCodes.platformUnavailable,
              )
              .having((error) => error.failure.retryable, 'retryable', isFalse)
              .having(
                (error) => error.failure.scope,
                'scope',
                YlFailureScope.player,
              ),
        ),
      );
    },
  );

  test('pubspec registers one shared implementation for iOS and macOS', () {
    final pubspec = _parseNestedYaml(
      File('${package.path}/pubspec.yaml').readAsStringSync(),
    );
    final flutter = _mapAt(pubspec, 'flutter');
    final plugin = _mapAt(flutter, 'plugin');
    final platforms = _mapAt(plugin, 'platforms');

    expect(plugin['implements'], 'yl_player');
    expect(platforms.keys, unorderedEquals(<String>['ios', 'macos']));
    for (final platform in platforms.values.cast<Map<String, Object?>>()) {
      expect(platform['pluginClass'], 'YlPlayerApplePlugin');
      expect(platform['dartPluginClass'], 'YlPlayerApple');
      expect(platform['sharedDarwinSource'], isTrue);
    }
  });

  test(
    'podspec exposes the shared artifact with platform-scoped metadata',
    () async {
      final podspec = '${package.path}/darwin/yl_player_apple.podspec';
      final result = await Process.run('pod', <String>['ipc', 'spec', podspec]);

      expect(result.exitCode, 0, reason: '${result.stderr}\n${result.stdout}');
      final spec = jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(
        spec['source_files'],
        'yl_player_apple/Sources/yl_player_apple/**/*.swift',
      );
      expect(
        spec['vendored_frameworks'],
        'yl_player_apple/Frameworks/YlFFmpegBridge.xcframework',
      );
      expect(spec['platforms'], <String, Object?>{
        'ios': '15.0',
        'osx': '12.0',
      });
      expect(spec['frameworks'], <String>[
        'AVFoundation',
        'AudioToolbox',
        'CoreMedia',
        'VideoToolbox',
        'AVFAudio',
        'Network',
        'QuartzCore',
      ]);

      final ios = _mapAt(spec, 'ios');
      final macos = _mapAt(spec, 'osx');
      expect(_mapAt(ios, 'dependencies').keys, <String>['Flutter']);
      expect(ios['frameworks'], 'UIKit');
      expect(_mapAt(macos, 'dependencies').keys, <String>['FlutterMacOS']);
      expect(macos['frameworks'], 'AppKit');
    },
  );

  test(
    'SwiftPM manifest declares the shared product and binary bridge',
    () async {
      final manifest = '${package.path}/darwin/yl_player_apple';
      final environment = Map<String, String>.of(Platform.environment)
        ..['SWIFTPM_MODULECACHE_OVERRIDE'] =
            '${Directory.systemTemp.path}/yl-player-apple-swiftpm-cache'
        ..['CLANG_MODULE_CACHE_PATH'] =
            '${Directory.systemTemp.path}/yl-player-apple-clang-cache';
      final result = await Process.run('swift', <String>[
        'package',
        '--disable-sandbox',
        'dump-package',
        '--package-path',
        manifest,
      ], environment: environment);

      expect(result.exitCode, 0, reason: '${result.stderr}\n${result.stdout}');
      final packageDump =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(packageDump['name'], 'yl_player_apple');
      expect(packageDump['platforms'], <Object?>[
        <String, Object?>{
          'options': <Object?>[],
          'platformName': 'ios',
          'version': '15.0',
        },
        <String, Object?>{
          'options': <Object?>[],
          'platformName': 'macos',
          'version': '12.0',
        },
      ]);

      final products = (packageDump['products'] as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(products, hasLength(1));
      expect(products.single['name'], 'yl-player-apple');
      expect(products.single['targets'], <String>['yl_player_apple']);

      final dependencies = (packageDump['dependencies'] as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(dependencies, hasLength(1));
      expect(jsonEncode(dependencies.single), contains('FlutterFramework'));

      final targets = (packageDump['targets'] as List<Object?>)
          .cast<Map<String, Object?>>();
      final bridge = targets.singleWhere(
        (target) => target['name'] == 'YlFFmpegBridge',
      );
      expect(bridge['type'], 'binary');
      expect(bridge['path'], 'Frameworks/YlFFmpegBridge.xcframework');
      final plugin = targets.singleWhere(
        (target) => target['name'] == 'yl_player_apple',
      );
      expect(plugin['type'], 'regular');
      expect(jsonEncode(plugin['dependencies']), contains('FlutterFramework'));
      expect(jsonEncode(plugin['dependencies']), contains('YlFFmpegBridge'));
    },
  );
}

Directory _findRepositoryRoot() {
  var directory = Directory.current.absolute;
  while (true) {
    if (File('${directory.path}/pubspec.yaml').existsSync() &&
        Directory('${directory.path}/packages').existsSync()) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Could not locate the yl_player workspace root.');
    }
    directory = parent;
  }
}

Map<String, Object?> _parseNestedYaml(String source) {
  final root = <String, Object?>{};
  final stack = <({int indent, Map<String, Object?> map})>[
    (indent: -1, map: root),
  ];

  for (final line in const LineSplitter().convert(source)) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) {
      continue;
    }
    final match = RegExp(r'^( *)([^:]+):(?: +(.*))?$').firstMatch(line);
    if (match == null) {
      continue;
    }
    final indent = match.group(1)!.length;
    while (stack.last.indent >= indent) {
      stack.removeLast();
    }
    final key = match.group(2)!.trim();
    final rawValue = match.group(3);
    if (rawValue == null || rawValue.isEmpty) {
      final child = <String, Object?>{};
      stack.last.map[key] = child;
      stack.add((indent: indent, map: child));
    } else {
      stack.last.map[key] = switch (rawValue) {
        'true' => true,
        'false' => false,
        _ => rawValue.replaceAll(RegExp(r'''^['"]|['"]$'''), ''),
      };
    }
  }
  return root;
}

Map<String, Object?> _mapAt(Map<String, Object?> map, String key) =>
    (map[key] as Map<Object?, Object?>).cast<String, Object?>();
