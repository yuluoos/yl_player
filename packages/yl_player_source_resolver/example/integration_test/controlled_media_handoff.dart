import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_source_resolver/src/script_http.dart';
import 'package:yl_player_source_resolver/yl_player_source_resolver.dart';

import '../../test/support/controlled_contract.dart';
import 'package:yl_script_resolver_example/demo_server.dart';

/// Frozen scripts execute unchanged in the controlled host environment. Only
/// the final media URI is remapped to our synthetic HLS. This proves native
/// handoff, first frame and stop, not availability of the original online media.
void registerControlledMediaHandoffs(Map<String, String> sources) {
  for (final entry in frozenScripts.entries) {
    testWidgets('${entry.key} controlled media handoff (owned URI remap)', (
      tester,
    ) async {
      final bytes = base64Decode(sources[entry.key]!);
      expect(sha256.convert(bytes).toString(), entry.value.$3);
      final resolver = YlScriptResolver();
      addTearDown(resolver.dispose);
      final resolved = await withScriptHttpFixture(
        (uri, method, headers, body) async =>
            fixtureResponse(entry.key, headers),
        () => resolver
            .resolveSource(
              controlledScriptSource(entry.key, utf8.decode(bytes)),
              parameters: entry.value.$2,
            )
            .result,
      );
      final converted = resolved.toNetworkSource();
      // Compression is negotiated by the native HTTP transport. Android
      // deliberately reserves Accept-Encoding rather than treating it as an
      // application credential (e.g. offering unsupported br/zstd decoders).
      final applicationCredentials = Map<String, String>.fromEntries(
        converted.request.credentials.entries.where(
          (entry) => entry.key.toLowerCase() != 'accept-encoding',
        ),
      );
      final server = await DemoServer.start(
        expectedCredentials: applicationCredentials,
      );
      addTearDown(server.close);
      final player = await YlPlayerController.create();
      final frames = <YlFirstFrameEvent>[];
      final subscription = player.events
          .where((event) => event is YlFirstFrameEvent)
          .cast<YlFirstFrameEvent>()
          .listen(frames.add);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: YlPlayerView(controller: player)),
          ),
        );
        debugPrint('P05_HANDOFF ${entry.key} loading');
        final session = await player
            .load(
              YlNetworkSource(
                server.hlsUri,
                request: converted.request,
                intent: converted.intent,
                format: converted.format,
                networkPolicy: converted.networkPolicy,
              ),
            )
            .timeout(const Duration(seconds: 30));
        debugPrint('P05_HANDOFF ${entry.key} loaded');
        await session.play().timeout(const Duration(seconds: 10));
        await session.ready.timeout(const Duration(seconds: 20));
        await session.firstFrame.timeout(const Duration(seconds: 20));
        debugPrint('P05_HANDOFF ${entry.key} firstFrame');
        expect(player.state.sessionId, session.id);
        expect(frames.any((event) => event.sessionId == session.id), isTrue);
        expect(
          player.state.engine,
          Platform.isAndroid
              ? YlPlaybackEngine.media3
              : YlPlaybackEngine.avPlayer,
        );
        expect(player.state.videoGeometry?.displaySize.width, greaterThan(0));
        expect(player.state.videoGeometry?.displaySize.height, greaterThan(0));
        expect(server.mediaRequests, greaterThan(0));
        if (applicationCredentials.isNotEmpty) {
          expect(server.credentialChecks, greaterThan(0));
          expect(server.credentialsMatched, isTrue);
        }
        await player.stop().timeout(const Duration(seconds: 10));
        final count = frames.length;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(frames.length, count);
        expect(player.state.sessionId, isNull);
      } finally {
        if (server.credentialMismatch != null) {
          debugPrint(
            'P05_CREDENTIAL ${entry.key} ${server.credentialMismatch}',
          );
        }
        await subscription.cancel();
        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose().timeout(const Duration(seconds: 10));
      }
    });
  }
}
