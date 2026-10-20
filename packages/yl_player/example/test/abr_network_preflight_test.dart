import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/abr_network_preflight.dart';

void main() {
  test(
    'clock alignment binds active identities and brackets server time',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final config = {
        'url': 'http://127.0.0.1:${server.port}/manifest.mpd',
        'runId': 'clock-run',
        'profileId': 'profile-v1',
        'profileHash': 'a' * 64,
        'mediaHash': 'b' * 64,
      };
      var bad = false;
      server.listen((request) async {
        for (final entry in {
          'X-Yl-Run-Id': bad ? 'other' : config['runId']!,
          'X-Yl-Profile-Id': config['profileId']!,
          'X-Yl-Profile-Sha256': config['profileHash']!,
          'X-Yl-Asset-Sha256': config['mediaHash']!,
          'X-Yl-Timeline-Mode': 'first-get',
          'X-Yl-Timeline-State': 'active',
          'X-Yl-Elapsed-Us': '300',
        }.entries) {
          request.response.headers.set(entry.key, entry.value);
        }
        await request.response.close();
      });
      var now = 400;
      final alignment = await alignAbrClock(config, nowUs: () => now += 600);
      expect(alignment, {'beforeUs': 1000, 'afterUs': 1600, 'serverUs': 300});
      bad = true;
      await expectLater(
        alignAbrClock(config, nowUs: () => now += 600),
        throwsA(isA<StateError>()),
      );
    },
  );
  test(
    'preflight timeout closes its actual socket before reporting cleanup',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final disconnected = Completer<void>();
      final accepted = Completer<void>();
      Socket? peer;
      final listener = server.listen((socket) {
        peer = socket;
        accepted.complete();
        socket.listen((_) {}, onDone: () => disconnected.complete());
      });
      addTearDown(() async {
        peer?.destroy();
        await listener.cancel();
        await server.close();
      });
      final request = preflightAbr({
        'url': 'http://127.0.0.1:${server.port}/manifest.mpd',
      }, timeout: const Duration(milliseconds: 50));
      await expectLater(request, throwsA(isA<TimeoutException>()));
      await accepted.future.timeout(const Duration(seconds: 1));
      final closed = await disconnected.future
          .then((_) => true)
          .timeout(const Duration(milliseconds: 300), onTimeout: () => false);
      expect(
        closed,
        isTrue,
        reason: 'Timeout must close the outstanding socket',
      );
    },
  );
}
