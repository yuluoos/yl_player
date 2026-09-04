import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

final class LiveFlvServer {
  LiveFlvServer._({
    required this._server,
    required this._bytes,
    required this.disconnectFirstConnection,
    required this.chunkSize,
    required this.chunkDelay,
  });

  static Future<LiveFlvServer> start({
    required String asset,
    bool disconnectFirstConnection = false,
    int chunkSize = 512,
    Duration chunkDelay = const Duration(milliseconds: 4),
  }) async {
    final assetData = await rootBundle.load(asset);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = LiveFlvServer._(
      server: server,
      bytes: assetData.buffer.asUint8List(
        assetData.offsetInBytes,
        assetData.lengthInBytes,
      ),
      disconnectFirstConnection: disconnectFirstConnection,
      chunkSize: chunkSize,
      chunkDelay: chunkDelay,
    );
    server.listen((request) => unawaited(result._handle(request)));
    return result;
  }

  final HttpServer _server;
  final Uint8List _bytes;
  final Completer<void> _closing = Completer<void>();
  final bool disconnectFirstConnection;
  final int chunkSize;
  final Duration chunkDelay;

  int connectionCount = 0;
  final List<Map<String, List<String>>> requestHeaders =
      <Map<String, List<String>>>[];

  Uri get streamUri => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _server.port,
    path: '/live.flv',
  );

  Future<void> close() async {
    if (!_closing.isCompleted) _closing.complete();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path != '/live.flv') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    connectionCount += 1;
    final connection = connectionCount;
    final headers = <String, List<String>>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = List<String>.unmodifiable(values);
    });
    requestHeaders.add(Map<String, List<String>>.unmodifiable(headers));

    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType('video', 'x-flv');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');

    try {
      for (var offset = 0; offset < _bytes.length; offset += chunkSize) {
        if (_closing.isCompleted) return;
        final end = (offset + chunkSize).clamp(0, _bytes.length);
        response.add(Uint8List.sublistView(_bytes, offset, end));
        await response.flush();
        await Future<void>.delayed(chunkDelay);
      }

      if (disconnectFirstConnection && connection == 1) {
        // The entire short fixture (and therefore its complete FLV header) has
        // been delivered. Destroy the socket to force the native live-retry
        // path instead of producing a normal VOD completion.
        final socket = await response.detachSocket();
        socket.destroy();
        return;
      }

      // A live response has no terminal content length. Leave the successful
      // reconnect open until teardown so the player remains at a live edge.
      await _closing.future;
      await response.close();
    } on Object {
      // Player cancellation and force-closing the server intentionally tear
      // down active sockets.
    }
  }
}
