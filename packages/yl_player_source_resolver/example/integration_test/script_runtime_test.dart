import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_source_resolver/yl_player_source_resolver.dart';
import 'package:yl_player_source_resolver/src/script_http.dart';
import 'package:yl_script_resolver_example/demo_server.dart';

Matcher failure(String code) =>
    isA<YlScriptException>().having((e) => e.code, 'code', 'script.$code');
const success =
    'function main(){return {url:"https://fixture.invalid/success"}}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerRuntimeContracts();
}

void registerRuntimeContracts() {
  test(
    'public native success raw parameters credentials and explicit RTMP rejection',
    () async {
      final resolver = YlScriptResolver();
      addTearDown(resolver.dispose);
      final result = await resolver
          .resolveSource(
            'function main(p){return {url:"https://fixture.invalid/"+p,headers:{"X-Fixture":"controlled"}}}',
            parameters: 'a%2Fb+c',
          )
          .result;
      expect(result.uri.path, '/a%2Fb+c');
      expect(result.toNetworkSource().request.credentials, {
        'x-fixture': 'controlled',
      });
      final rtmp = await resolver
          .resolveSource(
            'function main(){return {url:"rtmp://fixture.invalid/live"}}',
          )
          .result;
      expect(
        () => rtmp.toNetworkSource(),
        throwsA(failure('media_protocol_unsupported')),
      );
    },
  );
  for (final (name, source) in <(String, String)>[
    ('infinite JavaScript', 'function main(){while(true){}}'),
    (
      'pathological regular expression',
      'function main(){/(a+)+b/.test("a".repeat(100000));return {url:"https://fixture.invalid"}}',
    ),
  ]) {
    test('$name native deadline and reuse', () async {
      final resolver = YlScriptResolver(
        limits: const YlScriptLimits(timeout: Duration(milliseconds: 400)),
      );
      addTearDown(resolver.dispose);
      final clock = Stopwatch()..start();
      await expectLater(
        resolver.resolveSource(source).result,
        throwsA(failure('timeout')),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      expect(
        (await resolver.resolveSource(success).result).uri.host ==
            'fixture.invalid',
        isTrue,
      );
    });
  }
  test('live cancellation joins native work and new generation wins', () async {
    final resolver = YlScriptResolver();
    addTearDown(resolver.dispose);
    final entered = Completer<void>();
    final old = withScriptHttpFixture(
      (uri, method, headers, body) async {
        if (!entered.isCompleted) entered.complete();
        return ScriptHttpReply(200, utf8.encode('entered'));
      },
      () => resolver.resolveSource(
        'function main(){mytv.get("https://fixture.invalid/entered");while(true){}}',
      ),
    );
    var oldSuccesses = 0;
    final checked = expectLater(
      old.result.then((value) {
        oldSuccesses++;
        return value;
      }),
      throwsA(failure('cancelled')),
    );
    await entered.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await old.cancel();
    await checked;
    expect(
      (await resolver.resolveSource(success).result).uri.host ==
          'fixture.invalid',
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(oldSuccesses, 0);
  });
  test(
    'held real HTTP cancellation closes the server socket before reuse',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requested = Completer<void>();
      final disconnected = Completer<void>();
      Socket? peer;
      final sub = server.listen((socket) {
        peer = socket;
        socket.listen(
          (data) {
            if (!requested.isCompleted) requested.complete();
          },
          onDone: () {
            if (!disconnected.isCompleted) disconnected.complete();
          },
          onError: (Object _) {
            if (!disconnected.isCompleted) disconnected.complete();
          },
        );
      });
      addTearDown(() async {
        peer?.destroy();
        await sub.cancel();
      });
      final resolver = YlScriptResolver();
      addTearDown(resolver.dispose);
      final uri = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        path: '/held',
      );
      final job = resolver.resolveSource(
        'function main(){return {url:mytv.get(${jsonEncode(uri.toString())})}}',
      );
      final checked = expectLater(job.result, throwsA(failure('cancelled')));
      await requested.future.timeout(const Duration(seconds: 5));
      await job.cancel();
      await checked;
      await disconnected.future.timeout(const Duration(seconds: 5));
      expect(
        (await resolver.resolveSource(success).result).uri.host ==
            'fixture.invalid',
        isTrue,
      );
    },
  );
  test('memory failure is bounded and resolver reusable after cleanup', () async {
    final resolver = YlScriptResolver(
      limits: const YlScriptLimits(heapBytes: 8 * 1024 * 1024),
    );
    addTearDown(resolver.dispose);
    await expectLater(
      resolver
          .resolveSource(
            'function main(){const a=[];while(true)a.push(new Array(10000).fill(1))}',
          )
          .result,
      throwsA(failure('resource_limit')),
    );
    expect(
      (await resolver.resolveSource(success).result).uri.host ==
          'fixture.invalid',
      isTrue,
    );
  });
  testWidgets(
    'resolved HTTP result renders matching session firstFrame and stops',
    (tester) async {
      final server = await DemoServer.start();
      addTearDown(server.close);
      final resolver = YlScriptResolver();
      addTearDown(resolver.dispose);
      final resolved = await resolver
          .resolve(
            YlScriptReference(
              scriptUri: server.scriptUri,
              parameters: 'channel=synthetic',
            ),
          )
          .result;
      expect(resolved.uri == server.mediaUri, isTrue);
      final player = await YlPlayerController.create();
      addTearDown(player.dispose);
      final frames = <YlFirstFrameEvent>[];
      final sub = player.events
          .where((event) => event is YlFirstFrameEvent)
          .cast<YlFirstFrameEvent>()
          .listen(frames.add);
      addTearDown(sub.cancel);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: YlPlayerView(controller: player)),
        ),
      );
      final session = await player
          .load(resolved.toNetworkSource())
          .timeout(const Duration(seconds: 30));
      await session.play();
      await session.ready.timeout(const Duration(seconds: 20));
      await session.firstFrame.timeout(const Duration(seconds: 20));
      expect(player.state.sessionId, session.id);
      expect(frames.any((e) => e.sessionId == session.id), isTrue);
      expect(
        player.state.engine,
        Platform.isAndroid
            ? YlPlaybackEngine.media3
            : YlPlaybackEngine.avPlayer,
      );
      expect(player.state.videoGeometry?.displaySize.width, greaterThan(0));
      expect(player.state.videoGeometry?.displaySize.height, greaterThan(0));
      expect(server.mediaRequests, greaterThan(0));
      await player.stop();
      final frameCount = frames.length;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(frames.length, frameCount);
      expect(player.state.sessionId, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
