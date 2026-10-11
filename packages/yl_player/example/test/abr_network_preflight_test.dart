import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/abr_network_preflight.dart';

void main() {
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
