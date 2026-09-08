import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_apple/yl_player_apple.dart';
import 'package:yl_player_apple/src/pigeon/yl_player_apple.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'support/apple_fakes.dart';

void main() {
  final repository = _findRepositoryRoot();
  final package = Directory('${repository.path}/packages/yl_player_apple');
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const prefix = 'dev.flutter.pigeon.yl_player_apple';
  const codec = ApplePlayerHostApi.pigeonChannelCodec;

  void host(
    String method,
    FutureOr<Object?> Function(Object?) handler, {
    String suffix = '.instance-1',
  }) {
    final channel = BasicMessageChannel<Object?>(
      '$prefix.ApplePlayerHostApi.$method$suffix',
      codec,
    );
    messenger.setMockDecodedMessageHandler(
      channel,
      (message) async => handler(message),
    );
    addTearDown(() => messenger.setMockDecodedMessageHandler(channel, null));
  }

  void factory(FutureOr<Object?> Function(Object?) handler) {
    final channel = BasicMessageChannel<Object?>(
      '$prefix.ApplePlayerFactoryHostApi.create',
      ApplePlayerFactoryHostApi.pigeonChannelCodec,
    );
    messenger.setMockDecodedMessageHandler(
      channel,
      (message) async => handler(message),
    );
    addTearDown(() => messenger.setMockDecodedMessageHandler(channel, null));
  }

  Future<Object?> callback(
    String name,
    Object value, {
    String suffix = 'instance-1',
  }) async {
    final completion = Completer<Object?>();
    await messenger.handlePlatformMessage(
      '$prefix.ApplePlayerFlutterApi.$name.$suffix',
      codec.encodeMessage([value]),
      (data) {
        completion.complete(codec.decodeMessage(data));
      },
    );
    return completion.future;
  }

  test('registerWith installs v2 implementation', () {
    final previous = YlPlayerPlatform.instance;
    addTearDown(() => YlPlayerPlatform.instance = previous);
    YlPlayerApple.registerWith();
    expect(YlPlayerPlatform.instance, isA<YlPlayerApple>());
  });
  test(
    'production Pigeon wrappers create, route every command and remove suffix callbacks',
    () async {
      final calls = <String>[];
      factory((message) {
        final request = (message as List).single as AppleCreateRequest;
        expect(request.schemaMajor, 2);
        expect(request.options.audioPolicy, AppleAudioPolicy.appManaged);
        return [wireCreate()];
      });
      host('attach', (_) async {
        calls.add('attach');
        // Receiving a callback from attach proves setup precedes the host call.
        expect(
          await callback('onState', wireState(revision: 1, sequence: 1)),
          isEmpty,
        );
        return [];
      });
      host('assess', (message) {
        final request = (message as List).single as AppleAssessRequest;
        expect(request.source.kind, AppleSourceKind.network);
        return [
          AppleAssessmentReply(
            outcome: AppleAssessmentOutcome.compatible,
            satisfiedRequirements: [],
            limitations: [],
          ),
        ];
      });
      host('load', (message) async {
        final request = (message as List).single as AppleLoadRequest;
        expect(request.source.locator, 'https://media.test/a?token=secret');
        expect(request.options.videoConstraints.maxWidth, 1280);
        await callback(
          'onState',
          wireState(session: 's1', revision: 2, sequence: 2),
        );
        return [AppleLoadReply(loadRequestId: 'load-1', sessionId: 's1')];
      });
      for (final method in ['play', 'pause', 'seekToLiveEdge']) {
        host(method, (message) {
          expect(
            ((message as List).single as AppleSessionCommand).sessionId,
            's1',
          );
          calls.add(method);
          return [];
        });
      }
      host('seekTo', (message) {
        final command = (message as List).single as AppleSeekCommand;
        expect(command.sessionId, 's1');
        expect(command.positionMs, 3000);
        calls.add('seekTo');
        return [];
      });
      host('setPlaybackSpeed', (message) {
        final command = (message as List).single as AppleSpeedCommand;
        expect(command.sessionId, 's1');
        expect(command.speed, 1.25);
        calls.add('speed');
        return [];
      });
      host('selectAudioTrack', (message) {
        final command = (message as List).single as AppleTrackCommand;
        expect(command.sessionId, 's1');
        expect(command.trackId, 'audio-main');
        calls.add('track');
        return [];
      });
      host('setVideoConstraints', (message) {
        final command =
            (message as List).single as AppleVideoConstraintsCommand;
        expect(command.sessionId, 's1');
        expect(command.constraints.maxHeight, 720);
        calls.add('constraints');
        return [];
      });
      host('setVolume', (message) {
        expect((message as List).single, .5);
        calls.add('volume');
        return [];
      });
      host('stop', (_) {
        calls.add('stop');
        return [];
      });
      host('dispose', (_) {
        calls.add('dispose');
        return [];
      });
      final player = await YlPlayerApple().createPlayer(
        const YlPlayerOptions(),
      );
      final load = await player.load(
        source,
        options: const YlLoadOptions(
          videoConstraints: YlVideoConstraints(maxWidth: 1280),
        ),
      );
      await player.play(load.sessionId);
      await player.pause(load.sessionId);
      await player.seekTo(load.sessionId, const Duration(seconds: 3));
      await player.seekToLiveEdge(load.sessionId);
      await player.setPlaybackSpeed(load.sessionId, 1.25);
      await player.selectAudioTrack(load.sessionId, 'audio-main');
      await player.setVideoConstraints(
        load.sessionId,
        const YlVideoConstraints(maxHeight: 720),
      );
      await player.setVolume(.5);
      await player.stop();
      await player.dispose();
      expect(calls, [
        'attach',
        'play',
        'pause',
        'seekTo',
        'seekToLiveEdge',
        'speed',
        'track',
        'constraints',
        'volume',
        'stop',
        'dispose',
      ]);
      expect(await callback('onState', wireState()), isNull);
      expect(player.textureId.value, isNull);
    },
  );
  test(
    'production typed native rejection is safe; missing host is terminal',
    () async {
      factory((_) => [wireCreate()]);
      host('attach', (_) => []);
      host('dispose', (_) => []);
      host(
        'assess',
        (_) => [
          'native-failure',
          'secret',
          wireFailure(scope: AppleFailureScope.command),
        ],
      );
      final player = await YlPlayerApple().createPlayer(
        const YlPlayerOptions(),
      );
      await expectLater(
        player.assess(source),
        throwsA(
          isA<YlPlayerException>()
              .having(
                (e) => e.failure.message,
                'message',
                'Playback operation failed.',
              )
              .having(
                (e) => e.failure.diagnosticId,
                'diagnosticId',
                'apple-network-1',
              ),
        ),
      );
      // No setVolume host is registered: generated channel-error becomes terminal.
      await expectLater(
        player.setVolume(.5),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.platformUnavailable,
          ),
        ),
      );
      expect(player.state.failure!.scope, YlFailureScope.player);
      await player.dispose();
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
    '^\\s*${RegExp.escape(name)}\\s*=\\s*[\\\'"]([^\\\'"]+)[\\\'"]\\s*\$',
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
    '[\\\'"]([^\\\'"]+)[\\\'"]',
  ).allMatches(match.group(1)!).map((item) => item.group(1)!).toList();
}

Set<String> _rubyDependencies(String source, String platform) => RegExp(
  '^\\s*s\\.${RegExp.escape(platform)}\\.dependency\\s+[\\\'"]([^\\\'"]+)[\\\'"]',
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
