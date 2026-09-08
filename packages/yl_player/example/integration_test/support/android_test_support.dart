import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';

Matcher failureCode(String code) =>
    isA<YlPlayerException>().having((e) => e.failure.code, 'code', code);

Future<void> waitForState(
  YlPlayerController player,
  bool Function(YlPlayerState) predicate,
) async {
  if (predicate(player.state)) return;
  await player.states
      .firstWhere(predicate)
      .timeout(const Duration(seconds: 20));
}

// An owned endpoint holds headers so supersession occurs during real native I/O.
final class HeldAndroidServer {
  HeldAndroidServer._(this.server) {
    server.listen((request) {
      requests.add(request);
      if (!requested.isCompleted) requested.complete();
    });
  }
  static Future<HeldAndroidServer> start() async => HeldAndroidServer._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );
  final HttpServer server;
  final requested = Completer<void>();
  final requests = <HttpRequest>[];
  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/held');
  Future<void> close() async {
    await server.close(force: true);
  }
}
