import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

/// Valid baseline MKV, with about 300ms of initial packets delivered before the
/// remainder. Trailer/cue range reads remain available to the real extractor.
final class GatedAndroidMediaServer {
  GatedAndroidMediaServer._(this._server, this._bytes) {
    _server.listen((request) => unawaited(_serve(request)));
  }
  static Future<GatedAndroidMediaServer> start() async {
    final data = await rootBundle.load(
      'assets/test_media/network_seek_h264_aac.mkv',
    );
    return GatedAndroidMediaServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  static const prefixBytes = 160000;
  final HttpServer _server;
  final Uint8List _bytes;
  final requested = Completer<void>();
  final prefix = Completer<void>();
  final remainder = Completer<void>();
  final deliveredPrefix = Completer<void>();
  bool _closed = false;
  int bodyBytesSent = 0;
  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/gated.mkv');
  Future<void> _serve(HttpRequest request) async {
    if (!requested.isCompleted) requested.complete();
    await prefix.future;
    if (_closed) return;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range ?? '');
    final start = match == null ? 0 : int.parse(match.group(1)!);
    final end = match == null || match.group(2)!.isEmpty
        ? _bytes.length
        : int.parse(match.group(2)!) + 1;
    request.response.statusCode = range == null ? 200 : 206;
    request.response.contentLength = end - start;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (range != null) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${end - 1}/${_bytes.length}',
      );
    }
    try {
      if (start >= _bytes.length - 100000) {
        request.response.add(Uint8List.sublistView(_bytes, start, end));
      } else {
        final cut = prefixBytes.clamp(start, end);
        if (cut > start) {
          request.response.add(Uint8List.sublistView(_bytes, start, cut));
          await request.response.flush();
          bodyBytesSent += cut - start;
          if (!deliveredPrefix.isCompleted) deliveredPrefix.complete();
        }
        await remainder.future;
        if (_closed) return;
        request.response.add(Uint8List.sublistView(_bytes, cut, end));
      }
      await request.response.close();
    } on SocketException {
      // The extractor may cancel its initial stream to read trailer cues.
    } on HttpException {
      // The same deliberate extractor reopen may close the HTTP response.
    }
  }

  Future<void> close() async {
    _closed = true;
    if (!prefix.isCompleted) prefix.complete();
    if (!remainder.isCompleted) remainder.complete();
    await _server.close(force: true);
  }
}
