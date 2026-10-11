import 'dart:async';
import 'dart:io';

/// Owned byte-range origin; no external network or media fixture dependency.
final class RangeServer {
  RangeServer(this.server, this.bytes);
  final HttpServer server;
  final List<int> bytes;
  final requests = <HttpRequest>[];
  int sent = 0;
  FutureOr<void> Function(HttpRequest request, int index)? handle;
  static Future<RangeServer> start(List<int> bytes) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = RangeServer(server, bytes);
    server.listen((q) async {
      fixture.requests.add(q);
      if (fixture.handle case final handler?) {
        await handler(q, fixture.requests.length);
      } else {
        fixture.reply(q);
      }
    });
    return fixture;
  }

  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/media.mkv');
  (int, int) range(HttpRequest q) {
    final match = RegExp(
      r'^bytes=(\d+)-(\d+)$',
    ).firstMatch(q.headers.value('range') ?? '');
    if (match == null) throw StateError('Expected explicit single Range');
    return (int.parse(match[1]!), int.parse(match[2]!));
  }

  void reply(
    HttpRequest q, {
    String? etag = '"owned-v1"',
    String? contentRange,
    int? status,
    List<int>? body,
    bool chunked = false,
  }) {
    final (start, wanted) = range(q);
    final end = wanted.clamp(0, bytes.length - 1);
    final data = body ?? bytes.sublist(start, end + 1);
    q.response.statusCode = status ?? 206;
    q.response.headers.set(
      'content-range',
      contentRange ?? 'bytes $start-$end/${bytes.length}',
    );
    if (etag != null) q.response.headers.set('etag', etag);
    if (!chunked) q.response.contentLength = data.length;
    sent += data.length;
    q.response.add(data);
    unawaited(q.response.close());
  }

  Future<void> close() async {
    await server.close(force: true);
  }
}
