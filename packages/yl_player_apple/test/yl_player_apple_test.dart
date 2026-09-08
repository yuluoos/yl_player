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

  test('podspec exposes the shared artifact with platform-scoped metadata', () {
    final spec = File(
      '${package.path}/darwin/yl_player_apple.podspec',
    ).readAsStringSync();
    expect(
      _rubyStringAssignment(spec, 's.source_files'),
      'yl_player_apple/Sources/yl_player_apple/**/*.swift',
    );
    expect(
      _rubyStringAssignment(spec, 's.vendored_frameworks'),
      'yl_player_apple/Frameworks/YlFFmpegBridge.xcframework',
    );
    expect(_rubyStringAssignment(spec, 's.ios.deployment_target'), '15.0');
    expect(_rubyStringAssignment(spec, 's.osx.deployment_target'), '12.0');
    expect(_rubyStringListAssignment(spec, 's.frameworks'), <String>[
      'AVFoundation',
      'AudioToolbox',
      'CoreMedia',
      'VideoToolbox',
      'AVFAudio',
      'Network',
      'QuartzCore',
    ]);
    expect(_rubyStringListAssignment(spec, 's.ios.frameworks'), <String>[
      'UIKit',
    ]);
    expect(_rubyDependencies(spec, 'ios'), <String>{'Flutter'});
    expect(_rubyStringListAssignment(spec, 's.osx.frameworks'), <String>[
      'AppKit',
    ]);
    expect(_rubyDependencies(spec, 'osx'), <String>{'FlutterMacOS'});
  });

  test('SwiftPM manifest declares the shared product and binary bridge', () {
    final manifest = File(
      '${package.path}/darwin/yl_player_apple/Package.swift',
    ).readAsStringSync();
    expect(_swiftPackageName(manifest), 'yl_player_apple');
    expect(_swiftPlatformVersions(manifest), <String, String>{
      'iOS': '15.0',
      'macOS': '12.0',
    });
    expect(
      manifest,
      matches(
        RegExp(
          r'\.library\(\s*name:\s*"yl-player-apple",\s*'
          r'targets:\s*\["yl_player_apple"\]\s*\)',
        ),
      ),
    );
    expect(
      manifest,
      matches(
        RegExp(
          r'\.package\(\s*name:\s*"FlutterFramework",\s*'
          r'path:\s*"\.\./FlutterFramework"\s*\)',
        ),
      ),
    );
    expect(
      _swiftNamedCall(manifest, 'binaryTarget', 'YlFFmpegBridge'),
      contains('path: "Frameworks/YlFFmpegBridge.xcframework"'),
    );
    final pluginTarget = _swiftNamedCall(manifest, 'target', 'yl_player_apple');
    expect(pluginTarget, contains('FlutterFramework'));
    expect(pluginTarget, contains('YlFFmpegBridge'));
  });
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

String _rubyStringAssignment(String source, String name) {
  final match = RegExp(
    '^\\s*${RegExp.escape(name)}\\s*=\\s*[\\\'\"]([^\\\'\"]+)[\\\'\"]\\s*\$',
    multiLine: true,
  ).firstMatch(source);
  if (match == null) {
    throw StateError('Missing string assignment for $name.');
  }
  return match.group(1)!;
}

List<String> _rubyStringListAssignment(String source, String name) {
  final match = RegExp(
    '^\\s*${RegExp.escape(name)}\\s*=\\s*(.+)\$',
    multiLine: true,
  ).firstMatch(source);
  if (match == null) {
    throw StateError('Missing string-list assignment for $name.');
  }
  return RegExp(
    '[\\\'\"]([^\\\'\"]+)[\\\'\"]',
  ).allMatches(match.group(1)!).map((item) => item.group(1)!).toList();
}

Set<String> _rubyDependencies(String source, String platform) => RegExp(
  '^\\s*s\\.${RegExp.escape(platform)}\\.dependency\\s+[\\\'\"]([^\\\'\"]+)[\\\'\"]',
  multiLine: true,
).allMatches(source).map((match) => match.group(1)!).toSet();

String _swiftPackageName(String source) {
  final match = RegExp(r'Package\(\s*name:\s*"([^"]+)"').firstMatch(source);
  if (match == null) {
    throw StateError('Missing Swift package name.');
  }
  return match.group(1)!;
}

Map<String, String> _swiftPlatformVersions(String source) => <String, String>{
  for (final match in RegExp(
    r'\.(iOS|macOS)\("([0-9.]+)"\)',
  ).allMatches(source))
    match.group(1)!: match.group(2)!,
};

String _swiftNamedCall(String source, String call, String name) {
  final start = RegExp(
    '\\.${RegExp.escape(call)}\\(\\s*name:\\s*"${RegExp.escape(name)}"',
  ).firstMatch(source);
  if (start == null) {
    throw StateError('Missing Swift $call named $name.');
  }
  final tail = source.substring(start.start);
  final nextCall = RegExp(r'\n\s*\),?\n\s*\.').firstMatch(tail);
  return nextCall == null ? tail : tail.substring(0, nextCall.start + 3);
}
