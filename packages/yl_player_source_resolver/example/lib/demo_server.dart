import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Owned synthetic loopback fixture. No remote service is contacted.
final class DemoServer {
  DemoServer._(this._server, this._bytes, this._expectedCredentials);
  final HttpServer _server;
  final Uint8List _bytes;
  final Map<String, String> _expectedCredentials;
  int mediaRequests = 0;
  int credentialChecks = 0;
  bool credentialsMatched = true;
  String? credentialMismatch;
  // Frozen one-second fragments in assets/PROVENANCE.md; no new media bytes.
  static const _fragmentOffsets = [826, 14451, 38386, 69548, 103282];
  Uri get hlsUri => mediaUri.replace(path: '/fixture.m3u8');
  Uri get mediaUri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: _server.port,
    path: '/fixture.mp4',
  );
  Uri get scriptUri => mediaUri.replace(path: '/fixture.js');

  static Future<DemoServer> start({
    Map<String, String> expectedCredentials = const {},
  }) async {
    final data = await rootBundle.load('assets/fixture-video.mp4');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = DemoServer._(
      server,
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      Map.unmodifiable(expectedCredentials),
    );
    server.listen((request) => unawaited(fixture._serve(request)));
    return fixture;
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      if (_expectedCredentials.isNotEmpty) {
        credentialChecks++;
        credentialsMatched &= _expectedCredentials.entries.every((entry) {
          final actual = request.headers.value(entry.key);
          if (actual == entry.value) return true;
          credentialMismatch =
              'kind=${entry.key.toLowerCase() == 'accept-encoding' ? 'transportCompression' : 'application'} present=${actual != null}';
          return false;
        });
        if (!credentialsMatched) {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }
      }
      if (request.uri.path == '/fixture.m3u8') {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write(
          '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:1\n'
          '#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-MAP:URI="init.mp4"\n'
          '${List.generate(4, (index) => '#EXTINF:1.0,\nsegment$index.m4s\n').join()}'
          '#EXT-X-ENDLIST\n',
        );
      } else if (request.uri.path == '/fixture.js') {
        request.response.headers.contentType = ContentType(
          'application',
          'javascript',
        );
        request.response.write(
          'function main(p){return {url:${jsonEncode(mediaUri.toString())}}}',
        );
      } else if (request.uri.path == '/fixture.mp4' ||
          request.uri.path == '/init.mp4' ||
          RegExp(r'^/segment[0-3]\.m4s$').hasMatch(request.uri.path)) {
        mediaRequests++;
        final segment = RegExp(
          r'^/segment([0-3])\.m4s$',
        ).firstMatch(request.uri.path);
        final index = segment == null ? null : int.parse(segment.group(1)!);
        final bytes = request.uri.path == '/init.mp4'
            ? _bytes.sublist(0, _fragmentOffsets.first)
            : index == null
            ? _bytes
            : _bytes.sublist(
                _fragmentOffsets[index],
                _fragmentOffsets[index + 1],
              );
        final range = RegExp(
          r'^bytes=(\d+)-(\d*)$',
        ).firstMatch(request.headers.value('range') ?? '');
        final start = range == null ? 0 : int.parse(range.group(1)!);
        final end = range == null || range.group(2)!.isEmpty
            ? bytes.length - 1
            : int.parse(range.group(2)!).clamp(0, bytes.length - 1);
        if (start > end || start >= bytes.length) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          request.response.headers.set(
            'content-range',
            'bytes */${bytes.length}',
          );
        } else {
          request.response.headers.contentType = ContentType('video', 'mp4');
          request.response.headers.set('accept-ranges', 'bytes');
          if (range != null) {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/${bytes.length}',
            );
          }
          request.response.contentLength = end - start + 1;
          if (request.method != 'HEAD') {
            request.response.add(bytes.sublist(start, end + 1));
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
