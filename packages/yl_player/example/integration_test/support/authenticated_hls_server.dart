import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

final class RecordedHlsRequest {
  RecordedHlsRequest({
    required this.origin,
    required this.path,
    required Map<String, List<String>> headers,
  }) : headers = Map<String, List<String>>.unmodifiable(headers);

  final String origin;
  final String path;
  final Map<String, List<String>> headers;

  String? header(String name) => headers[name.toLowerCase()]?.join(',');
}

final class AuthenticatedHlsServer {
  AuthenticatedHlsServer._({
    required this._primary,
    required this._secondary,
    required this._key,
    required this._segment,
  });

  static Future<AuthenticatedHlsServer> start() async {
    final values = await Future.wait<ByteData>(<Future<ByteData>>[
      rootBundle.load('assets/test_media/hls_key.bin'),
      rootBundle.load('assets/test_media/hls_encrypted_segment0.ts'),
    ]);
    final primary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final secondary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = AuthenticatedHlsServer._(
      primary: primary,
      secondary: secondary,
      key: _bytes(values[0]),
      segment: _bytes(values[1]),
    );
    primary.listen((request) => unawaited(result._handlePrimary(request)));
    secondary.listen((request) => unawaited(result._handleSecondary(request)));
    return result;
  }

  final HttpServer _primary;
  final HttpServer _secondary;
  final Uint8List _key;
  final Uint8List _segment;
  final List<RecordedHlsRequest> requests = <RecordedHlsRequest>[];

  Uri get masterUri => _uri(_primary, '/master.m3u8');

  List<RecordedHlsRequest> requestsFor(String path) =>
      requests.where((request) => request.path == path).toList(growable: false);

  Future<void> close() async {
    await Future.wait<void>(<Future<void>>[
      _primary.close(force: true),
      _secondary.close(force: true),
    ]);
  }

  Future<void> _handlePrimary(HttpRequest request) async {
    _record('primary', request);
    switch (request.uri.path) {
      case '/master.m3u8':
        final child = _uri(_secondary, '/media.m3u8');
        request.response.headers.set(
          HttpHeaders.setCookieHeader,
          'origin-cookie=must-not-cross-port; Path=/',
        );
        await _serveText(
          request.response,
          '#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=350000,'
          'CODECS="avc1.42c00d,mp4a.40.2",RESOLUTION=320x180\n'
          '$child\n',
        );
      case '/key.bin':
        await _serveBytes(request.response, _key, ContentType.binary);
      default:
        await _notFound(request.response);
    }
  }

  Future<void> _handleSecondary(HttpRequest request) async {
    _record('secondary', request);
    switch (request.uri.path) {
      case '/media.m3u8':
        final key = _uri(_primary, '/key.bin');
        await _serveText(
          request.response,
          '#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-TARGETDURATION:2\n'
          '#EXT-X-MEDIA-SEQUENCE:0\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="$key",'
          'IV=0x00000000000000000000000000000000\n'
          '#EXTINF:1.968000,\n'
          'segment0.ts\n'
          '#EXT-X-ENDLIST\n',
        );
      case '/segment0.ts':
        await _serveBytes(
          request.response,
          _segment,
          ContentType('video', 'mp2t'),
        );
      default:
        await _notFound(request.response);
    }
  }

  void _record(String origin, HttpRequest request) {
    final headers = <String, List<String>>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = List<String>.unmodifiable(values);
    });
    requests.add(
      RecordedHlsRequest(
        origin: origin,
        path: request.uri.path,
        headers: headers,
      ),
    );
  }

  Future<void> _serveText(HttpResponse response, String value) => _serveBytes(
    response,
    Uint8List.fromList(value.codeUnits),
    ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8'),
  );

  Future<void> _serveBytes(
    HttpResponse response,
    Uint8List bytes,
    ContentType contentType,
  ) async {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = contentType;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  Future<void> _notFound(HttpResponse response) async {
    response.statusCode = HttpStatus.notFound;
    response.contentLength = 0;
    await response.close();
  }

  static Uri _uri(HttpServer server, String path) => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: server.port,
    path: path,
  );

  static Uint8List _bytes(ByteData data) =>
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
