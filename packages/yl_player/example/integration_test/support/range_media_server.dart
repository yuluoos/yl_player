import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/services.dart';

enum RangeMediaResponseKind {
  automatic,
  range,
  sequential,
  redirect,
  status,
  disconnect,
  truncated,
}

final class RangeMediaResponse {
  const RangeMediaResponse._(this.kind, {this.statusCode, this.prefixBytes});
  const RangeMediaResponse.automatic()
    : this._(RangeMediaResponseKind.automatic);
  const RangeMediaResponse.range() : this._(RangeMediaResponseKind.range);
  const RangeMediaResponse.sequential()
    : this._(RangeMediaResponseKind.sequential);
  const RangeMediaResponse.redirect() : this._(RangeMediaResponseKind.redirect);
  const RangeMediaResponse.status(int statusCode)
    : this._(RangeMediaResponseKind.status, statusCode: statusCode);
  const RangeMediaResponse.disconnect()
    : this._(RangeMediaResponseKind.disconnect);
  const RangeMediaResponse.truncated(int prefixBytes)
    : this._(RangeMediaResponseKind.truncated, prefixBytes: prefixBytes);

  final int? prefixBytes;
  final RangeMediaResponseKind kind;
  final int? statusCode;
}

final class RecordedMediaRequest {
  RecordedMediaRequest({
    required this.method,
    required this.uri,
    required Map<String, List<String>> headers,
  }) : headers = Map<String, List<String>>.unmodifiable(headers);

  final String method;
  final Uri uri;
  final Map<String, List<String>> headers;
  int? statusCode;
  int? truncatedAt;

  String? header(String name) => headers[name.toLowerCase()]?.join(',');
}

final class RangeMediaServer {
  RangeMediaServer._({
    required this._server,
    required this._bytes,
    required this.supportsRanges,
    this.beforeResponse,
    this.redirectUri,
    this.etag,
    required Iterable<RangeMediaResponse> scriptedResponses,
  }) : _scriptedResponses = Queue<RangeMediaResponse>.of(scriptedResponses);

  static Future<RangeMediaServer> start({
    required String asset,
    bool supportsRanges = true,
    Future<void> Function(RecordedMediaRequest)? beforeResponse,
    Uri? redirectUri,
    String? etag,
    Iterable<RangeMediaResponse> scriptedResponses =
        const <RangeMediaResponse>[],
  }) async {
    final assetData = await rootBundle.load(asset);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = RangeMediaServer._(
      server: server,
      bytes: assetData.buffer.asUint8List(
        assetData.offsetInBytes,
        assetData.lengthInBytes,
      ),
      supportsRanges: supportsRanges,
      beforeResponse: beforeResponse,
      redirectUri: redirectUri,
      etag: etag,
      scriptedResponses: scriptedResponses,
    );
    server.listen((request) => unawaited(result._handle(request)));
    return result;
  }

  final HttpServer _server;
  final Uint8List _bytes;
  final Queue<RangeMediaResponse> _scriptedResponses;
  final bool supportsRanges;
  final Future<void> Function(RecordedMediaRequest)? beforeResponse;
  final Uri? redirectUri;
  final String? etag;
  final List<RecordedMediaRequest> requests = <RecordedMediaRequest>[];

  int get lengthInBytes => _bytes.length;

  Uri get mediaUri => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _server.port,
    path: '/media',
  );

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final recorded = RecordedMediaRequest(
      method: request.method,
      uri: request.uri,
      headers: _copyHeaders(request.headers),
    );
    requests.add(recorded);
    final scripted = _scriptedResponses.isEmpty
        ? const RangeMediaResponse.automatic()
        : _scriptedResponses.removeFirst();

    try {
      await beforeResponse?.call(recorded);
      if (etag != null) {
        request.response.headers.set(HttpHeaders.etagHeader, etag!);
      }
      switch (scripted.kind) {
        case RangeMediaResponseKind.truncated:
          await _serveRange(
            request,
            recorded,
            prefixBytes: scripted.prefixBytes,
          );
        case RangeMediaResponseKind.disconnect:
          final socket = await request.response.detachSocket();
          socket.destroy();
        case RangeMediaResponseKind.redirect:
          recorded.statusCode = HttpStatus.found;
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            redirectUri?.toString() ?? '/media',
          );
          await request.response.close();
        case RangeMediaResponseKind.status:
          recorded.statusCode = scripted.statusCode;
          request.response.statusCode = scripted.statusCode!;
          request.response.contentLength = 0;
          await request.response.close();
        case RangeMediaResponseKind.sequential:
          await _serveSequential(request.response, recorded);
        case RangeMediaResponseKind.range:
          await _serveRange(request, recorded);
        case RangeMediaResponseKind.automatic:
          if (supportsRanges) {
            await _serveRange(request, recorded);
          } else {
            await _serveSequential(request.response, recorded);
          }
      }
    } on Object {
      // Disconnect scripts and force-closing a test server intentionally end a
      // request without a response. Other failures are surfaced to the client.
      if (scripted.kind != RangeMediaResponseKind.disconnect) rethrow;
    }
  }

  Future<void> _serveSequential(
    HttpResponse response,
    RecordedMediaRequest recorded,
  ) async {
    recorded.statusCode = HttpStatus.ok;
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.binary;
    response.contentLength = _bytes.length;
    response.add(_bytes);
    await response.close();
  }

  Future<void> _serveRange(
    HttpRequest request,
    RecordedMediaRequest recorded, {
    int? prefixBytes,
  }) async {
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final parsed = range == null ? (0, _bytes.length - 1) : _parseRange(range);
    if (parsed == null) {
      recorded.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */${_bytes.length}',
      );
      request.response.contentLength = 0;
      await request.response.close();
      return;
    }

    final (start, end) = parsed;
    final status = range == null ? HttpStatus.ok : HttpStatus.partialContent;
    recorded.statusCode = status;
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.binary;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (range != null) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${_bytes.length}',
      );
    }
    request.response.contentLength = end - start + 1;
    if (prefixBytes != null) {
      if (prefixBytes <= 0 || start + prefixBytes > end) {
        throw RangeError.value(prefixBytes);
      }
      final cut = start + prefixBytes;
      final socket = await request.response.detachSocket();
      socket.add(Uint8List.sublistView(_bytes, start, cut));
      await socket.flush();
      recorded.truncatedAt = cut;
      await socket.close();
      return;
    }
    request.response.add(Uint8List.sublistView(_bytes, start, end + 1));
    await request.response.close();
  }

  (int, int)? _parseRange(String? value) {
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(value ?? '');
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final requestedEnd = match.group(2)!.isEmpty
        ? _bytes.length - 1
        : int.tryParse(match.group(2)!);
    if (start == null || requestedEnd == null || start >= _bytes.length) {
      return null;
    }
    final end = requestedEnd.clamp(start, _bytes.length - 1);
    return (start, end);
  }

  static Map<String, List<String>> _copyHeaders(HttpHeaders headers) {
    final result = <String, List<String>>{};
    headers.forEach((name, values) {
      result[name.toLowerCase()] = List<String>.unmodifiable(values);
    });
    return result;
  }
}
