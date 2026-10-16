import 'dart:io';
import 'dart:typed_data';

/// Owned immutable fixture server for managed HTTP acceptance, not impairment.
/// Receipts describe actual authorized playback requests, not a second download.
class BoundSource {
  BoundSource._(this._server, this._bytes, this._name, this._run, this._hash);
  final HttpServer _server;
  final Uint8List _bytes;
  final String _name, _run, _hash;
  int _requests = 0, _served = 0, _rejected = 0;
  static Future<BoundSource> serve(
    Uint8List bytes,
    String name,
    String run,
    String hash,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final source = BoundSource._(
      server,
      Uint8List.fromList(bytes),
      name,
      run,
      hash,
    );
    server.listen(source._handle);
    return source;
  }

  Uri get uri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: _server.port,
    path: '/$_name',
  );
  Map<String, Object> get receipt => {
    'runId': _run,
    'mediaHash': _hash,
    'requests': _requests,
    'bytesServed': _served,
    'rejected': _rejected,
  };
  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.uri.path != '/$_name' ||
          request.headers.value('x-yl-bound-run') != _run ||
          !['GET', 'HEAD'].contains(request.method)) {
        _rejected++;
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      var start = 0, end = _bytes.length - 1;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
        if (match == null) {
          response.statusCode = 416;
          return;
        }
        start = int.parse(match[1]!);
        if (match[2]!.isNotEmpty) end = int.parse(match[2]!).clamp(0, end);
        if (start > end) {
          response.statusCode = 416;
          return;
        }
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${_bytes.length}',
        );
      }
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.contentType = ContentType.binary;
      response.contentLength = end - start + 1;
      _requests++;
      if (request.method != 'HEAD') {
        response.add(_bytes.sublist(start, end + 1));
        _served += end - start + 1;
      }
    } finally {
      try {
        await response.close();
      } on SocketException {
        /* Player cancelled a range. */
      }
    }
  }

  Future<void> close() async {
    await _server.close(force: true);
  }
}
