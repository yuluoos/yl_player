import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Owned synthetic loopback fixture. No remote service is contacted.
final class DemoServer {
  DemoServer._(this._server, this._bytes);
  final HttpServer _server;
  final Uint8List _bytes;
  int mediaRequests = 0;
  Uri get mediaUri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: _server.port,
    path: '/fixture.mp4',
  );
  Uri get scriptUri => mediaUri.replace(path: '/fixture.js');

  static Future<DemoServer> start() async {
    final data = await rootBundle.load('assets/fixture-video.mp4');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = DemoServer._(
      server,
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    server.listen((request) => unawaited(fixture._serve(request)));
    return fixture;
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      if (request.uri.path == '/fixture.js') {
        request.response.headers.contentType = ContentType(
          'application',
          'javascript',
        );
        request.response.write(
          'function main(p){return {url:${jsonEncode(mediaUri.toString())}}}',
        );
      } else if (request.uri.path == '/fixture.mp4') {
        mediaRequests++;
        final range = RegExp(
          r'^bytes=(\d+)-(\d*)$',
        ).firstMatch(request.headers.value('range') ?? '');
        final start = range == null ? 0 : int.parse(range.group(1)!);
        final end = range == null || range.group(2)!.isEmpty
            ? _bytes.length - 1
            : int.parse(range.group(2)!).clamp(0, _bytes.length - 1);
        if (start > end || start >= _bytes.length) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          request.response.headers.set(
            'content-range',
            'bytes */${_bytes.length}',
          );
        } else {
          request.response.headers.contentType = ContentType('video', 'mp4');
          request.response.headers.set('accept-ranges', 'bytes');
          if (range != null) {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/${_bytes.length}',
            );
          }
          request.response.contentLength = end - start + 1;
          if (request.method != 'HEAD') {
            request.response.add(_bytes.sublist(start, end + 1));
          }
        }
      } else {
        request.response.statusCode = HttpStatus.forbidden;
      }
      await request.response.close();
    } on SocketException {
      // The player may close a range request while stopping.
    } on HttpException {
      // The owner may close the fixture during teardown.
    }
  }

  Future<void> close() => _server.close(force: true);
}
