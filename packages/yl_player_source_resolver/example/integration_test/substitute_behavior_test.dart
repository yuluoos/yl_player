import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_source_resolver/src/script_http.dart';
import 'package:yl_player_source_resolver/yl_player_source_resolver.dart';
import 'package:yl_script_resolver_example/demo_server.dart';

import '../../test/support/controlled_contract.dart';
import '../../test/support/substitute_scripts.dart';

String digest(String value) => md5.convert(utf8.encode(value)).toString();

void checkMediaUri(String id, Uri actual, Uri expected, String parameters) {
  expect(actual.origin, expected.origin);
  expect(actual.path, expected.path);
  expect(actual.hasFragment, isFalse);
  final query = actual.queryParameters;
  if (id == 'JS-07') {
    expect(query.keys.toSet(), {'sign', 't'});
    final t = query['t']!;
    expect(t, matches(RegExp(r'^[a-f0-9]{8}$')));
    expect(query['sign'], digest('192.0.2.1|fixture-key|${expected.path}|$t'));
  } else if (id == 'JS-09') {
    expect(query.keys.toSet(), {'auth_key'});
    final parts = query['auth_key']!.split('-');
    expect(parts, hasLength(4));
    expect(parts[0], matches(RegExp(r'^\d{10}$')));
    expect(parts[1], digest(parameters));
    expect(parts[2], '0');
    expect(
      parts[3],
      digest('${expected.path}|${parts.take(3).join('-')}|fixture'),
    );
  } else {
    expect(actual, expected);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final id in frozenScripts.keys) {
    final script = substituteScripts[id]!;
    testWidgets('$id substitute behavior and Media3 handoff', (tester) async {
      final params = frozenScripts[id]!.$2;
      final expectedHeaders = switch (id) {
        'JS-05' => {'x-channel': 'hnws'},
        'JS-07' => {'referer': 'https://fixture.invalid/'},
        _ => <String, String>{},
      };
      final media = await DemoServer.start(
        expectedCredentials: expectedHeaders,
      );
      addTearDown(media.close);
      final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => host.close(force: true));
      final api = Uri.parse('http://127.0.0.1:${host.port}/$id');
      final calls = <(String, String, List<int>, String?)>[];
      final held = Completer<void>();
      final disconnected = Completer<void>();
      var holdRequest = id != 'JS-09';
      var returnReportedError = false;
      host.listen((request) async {
        final body = await request.fold(<int>[], (a, b) => a..addAll(b));
        calls.add((
          request.method,
          request.uri.toString(),
          body,
          request.headers.value('host'),
        ));
        if (holdRequest) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.listen(
            (_) {},
            onDone: () {
              socket.destroy();
              if (!disconnected.isCompleted) disconnected.complete();
            },
          );
          held.complete();
          return;
        }
        final headers = <String, String>{};
        request.headers.forEach(
          (key, values) => headers[key] = values.join(','),
        );
        try {
          final reply = fixtureResponse(
            id,
            headers,
            mediaUrl: media.hlsUri.toString(),
          );
          final data =
              jsonDecode(utf8.decode(reply.bytes)) as Map<String, dynamic>;
          if (returnReportedError) data['error'] = 'fixture error';
          // Wrong first entry makes matching the requested channel observable.
          if (id == 'JS-06') {
            (data['dt'] as List).insert(0, {'id': 0, 'channelUrl': 'bad'});
          }
          if (id == 'JS-08') {
            (data['data'] as List).insert(0, {'Id': 0, 'PlayStreamUrl': 'bad'});
          }
          request.response.write(jsonEncode(data));
        } catch (_) {
          request.response.statusCode = 500;
        } finally {
          await request.response.close();
        }
      });
      final resolver = YlScriptResolver();
      addTearDown(resolver.dispose);
      String bind(String authority) =>
          'const api=${jsonEncode(api.toString())}, authority=${jsonEncode(authority)}, '
          'media=${jsonEncode(media.hlsUri.toString())};\n$script';
      final source = bind(api.authority);
      final cancelled = resolver.resolveSource(source, parameters: params);
      final cancellation = expectLater(
        cancelled.result,
        throwsA(
          isA<YlScriptException>().having(
            (e) => e.code,
            'code',
            'script.cancelled',
          ),
        ),
      );
      if (holdRequest) await held.future.timeout(const Duration(seconds: 5));
      await cancelled.cancel();
      await cancellation;
      if (holdRequest) {
        await disconnected.future.timeout(const Duration(seconds: 5));
      }
      holdRequest = false;

      var hostFailures = 0;
      if (id != 'JS-09') {
        await expectLater(
          withScriptHttpFixture((uri, method, headers, body) async {
            hostFailures++;
            throw const SocketException('controlled host unavailable');
          }, () => resolver.resolveSource(source, parameters: params)).result,
          throwsA(
            isA<YlScriptException>()
                .having((e) => e.phase, 'phase', 'host')
                .having((e) => e.code, 'code', 'script.execution'),
          ),
        );
        expect(hostFailures, 1);
      }
      if (id == 'JS-01') {
        returnReportedError = true;
        await expectLater(
          resolver.resolveSource(source, parameters: params).result,
          throwsA(
            isA<YlScriptException>().having(
              (e) => e.code,
              'code',
              'script.reported_error',
            ),
          ),
        );
        returnReportedError = false;
      }
      if (id == 'JS-03') {
        final before = calls.length;
        await expectLater(
          resolver
              .resolveSource(bind('wrong.invalid'), parameters: params)
              .result,
          throwsA(isA<YlScriptException>()),
        );
        expect(calls.length, before);
      }

      final before = calls.length;
      late YlResolvedSource resolved;
      Future<YlResolvedSource> resolve() =>
          resolver.resolveSource(source, parameters: params).result;
      var unexpectedRequests = 0;
      for (var run = 0; run < 2; run++) {
        // JS-09 signs locally. Fail even if it tries a different host from our
        // loopback server and catches the resulting error inside the script.
        resolved = id == 'JS-09'
            ? await withScriptHttpFixture((uri, method, headers, body) async {
                unexpectedRequests++;
                throw StateError('Unexpected network call in local signer');
              }, resolve)
            : await resolve();
        checkMediaUri(id, resolved.uri, media.hlsUri, params);
        expect(resolved.expiresAt, isNull);
        expect(resolved.headers, expectedHeaders);
      }
      expect(unexpectedRequests, 0);
      final successCalls = calls.length - before;
      expect(successCalls, id == 'JS-09' ? 0 : 2);
      for (final (method, target, body, authority) in calls) {
        expect(method, id == 'JS-06' ? 'POST' : 'GET');
        expect(target, '${api.path}?$params');
        expect(body, id == 'JS-06' ? utf8.encode('{}') : isEmpty);
        expect(authority, api.authority);
      }
      final player = await YlPlayerController.create();
      addTearDown(player.dispose);
      final frames = <YlFirstFrameEvent>[];
      final sub = player.events
          .where((e) => e is YlFirstFrameEvent)
          .cast<YlFirstFrameEvent>()
          .listen(frames.add);
      addTearDown(sub.cancel);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: YlPlayerView(controller: player),
        ),
      );
      final session = await player
          .load(resolved.toNetworkSource())
          .timeout(const Duration(seconds: 30));
      await session.play().timeout(const Duration(seconds: 10));
      await session.firstFrame.timeout(const Duration(seconds: 20));
      expect(player.state.engine, YlPlaybackEngine.media3);
      expect(player.state.sessionId, session.id);
      expect(frames.any((event) => event.sessionId == session.id), isTrue);
      expect(player.state.videoGeometry?.displaySize.width, greaterThan(0));
      expect(media.mediaRequests, greaterThan(0));
      if (expectedHeaders.isNotEmpty) {
        expect(media.credentialChecks, greaterThan(0));
        expect(media.credentialsMatched, isTrue);
      }
      await player.stop().timeout(const Duration(seconds: 10));
      final count = frames.length;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(frames.length, count);
      expect(player.state.sessionId, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      final evidence = {
        'id': id,
        'templateSha256': sha256.convert(utf8.encode(script)).toString(),
        'executedSha256': sha256.convert(utf8.encode(source)).toString(),
        'resolutions': 2,
        'successHostCalls': successCalls,
        'hostFailures': hostFailures,
        'cancelled': true,
        'heldSocketClosed': id == 'JS-09' ? null : disconnected.isCompleted,
        'mediaRequests': media.mediaRequests,
        'credentialChecks': media.credentialChecks,
        'matchingFirstFrame': true,
        'sessionCleared': true,
        'lateFrameWindowMs': 200,
      };
      debugPrint('YL_SUBSTITUTE=${jsonEncode(evidence)}');
    });
  }
}
