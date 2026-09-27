import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'dash_offset_fixture.dart';

enum DashOriginMode { sameOrigin, crossOrigin, returnToPrimary }

final class RecordedDashRequest {
  RecordedDashRequest({
    required this.origin,
    required this.path,
    required Map<String, List<String>> headers,
  }) : headers = Map<String, List<String>>.unmodifiable(headers);

  final String origin;
  final String path;
  final Map<String, List<String>> headers;

  String? header(String name) => headers[name.toLowerCase()]?.join(',');
}

final class DashServer {
  DashServer._({
    required this._primary,
    required this._secondary,
    required this._files,
    required this._manifest,
    required this.originMode,
    required this.failMedia,
    required this.delayMedia,
    required this.delayManifest,
    required this.manifestOverride,
    required this.rootStatusCode,
    required this.missingMedia,
  });

  static const _assetRoot = 'assets/test_media/dash';
  static const _fileNames = <String>[
    'period0/init-0.m4s',
    'period0/init-1.m4s',
    'period0/chunk-0-00001.m4s',
    'period0/chunk-0-00002.m4s',
    'period0/chunk-0-00003.m4s',
    'period0/chunk-0-00004.m4s',
    'period0/chunk-1-00001.m4s',
    'period0/chunk-1-00002.m4s',
    'period0/chunk-1-00003.m4s',
    'period0/chunk-1-00004.m4s',
    'period0/chunk-1-00005.m4s',
    'period1/init-0.m4s',
    'period1/init-1.m4s',
    'period1/chunk-0-00001.m4s',
    'period1/chunk-0-00002.m4s',
    'period1/chunk-0-00003.m4s',
    'period1/chunk-0-00004.m4s',
    'period1/chunk-1-00001.m4s',
    'period1/chunk-1-00002.m4s',
    'period1/chunk-1-00003.m4s',
    'period1/chunk-1-00004.m4s',
    'period1/chunk-1-00005.m4s',
  ];

  static Future<DashServer> start({
    DashOriginMode originMode = DashOriginMode.sameOrigin,
    bool variants = false,
    bool presentationOffsets = false,
    bool offsetSegmentList = false,
    bool failMedia = false,
    bool delayMedia = false,
    bool delayManifest = false,
    String? manifestOverride,
    int? rootStatusCode,
    bool missingMedia = false,
  }) async {
    if (offsetSegmentList && !presentationOffsets) {
      throw ArgumentError('Offset SegmentList requires presentationOffsets');
    }
    final useVariants = variants || presentationOffsets;
    final assetRoot = useVariants
        ? 'assets/test_media/dash_variants'
        : _assetRoot;
    final fileNames = useVariants
        ? <String>[
            for (final period in [0, 1])
              for (final track in [0, 1, 2]) ...[
                'period$period/init-$track.m4s',
                for (
                  var segment = 1;
                  segment <= (track == 2 ? 5 : 4);
                  segment++
                )
                  'period$period/chunk-$track-${segment.toString().padLeft(5, '0')}.m4s',
              ],
          ]
        : _fileNames;
    final loaded = await Future.wait<ByteData>([
      rootBundle.load('$assetRoot/manifest.mpd'),
      for (final name in fileNames) rootBundle.load('$assetRoot/$name'),
    ]);
    final primary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final secondary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final files = <String, Uint8List>{};
    for (var index = 0; index < fileNames.length; index += 1) {
      files['/${fileNames[index]}'] = _bytes(loaded[index + 1]);
    }
    var manifest = utf8.decode(_bytes(loaded.first));
    if (presentationOffsets) {
      final shifted = DashOffsetFixture.fromVariants(
        files,
        segmentList: offsetSegmentList,
      );
      manifest = shifted.manifest;
      files
        ..clear()
        ..addAll(shifted.files);
    }
    final result = DashServer._(
      primary: primary,
      secondary: secondary,
      files: files,
      manifest: manifest,
      originMode: originMode,
      failMedia: failMedia,
      delayMedia: delayMedia,
      delayManifest: delayManifest,
      manifestOverride: manifestOverride,
      rootStatusCode: rootStatusCode,
      missingMedia: missingMedia,
    );
    primary.listen((request) => result._accept('primary', request));
    secondary.listen((request) => result._accept('secondary', request));
    return result;
  }

  final DashOriginMode originMode;
  final bool failMedia;
  final bool delayMedia;
  final bool delayManifest;
  final String? manifestOverride;
  final int? rootStatusCode;
  final bool missingMedia;
  final Completer<void> _manifestGate = Completer<void>();
  final Completer<void> _manifestEntered = Completer<void>();
  final Completer<void> _mediaEntered = Completer<void>();
  final Set<Future<void>> _handlers = <Future<void>>{};
  final List<(Object, StackTrace)> _handlerErrors = [];
  bool _closed = false;

  Future<void> get manifestEntered => _manifestEntered.future;
  Future<void> get mediaEntered => _mediaEntered.future;
  final HttpServer _primary;
  final HttpServer _secondary;
  final Map<String, Uint8List> _files;
  final String _manifest;
  final Completer<void> _mediaGate = Completer<void>();
  final List<RecordedDashRequest> requests = <RecordedDashRequest>[];

  Uri get automaticUri => _uri(_primary, '/manifest.mpd');
  Uri get explicitUri => _uri(_primary, '/explicit');
  Uri get redirectUri => _uri(_primary, '/redirect.mpd');

  List<RecordedDashRequest> requestsFor(String path) =>
      requests.where((request) => request.path == path).toList(growable: false);

  Iterable<RecordedDashRequest> get childRequests =>
      requests.where((request) => request.path.endsWith('.m4s'));

  void releaseDelayedMedia() {
    if (!_mediaGate.isCompleted) _mediaGate.complete();
  }

  void releaseDelayedManifest() {
    if (!_manifestGate.isCompleted) _manifestGate.complete();
  }

  Future<void> settle() async {
    await Future.wait(_handlers.toList()).timeout(const Duration(seconds: 5));
    if (_handlerErrors.isNotEmpty) {
      final (error, stack) = _handlerErrors.removeAt(0);
      Error.throwWithStackTrace(error, stack);
    }
  }

  void _accept(String origin, HttpRequest request) {
    late final Future<void> handler;
    handler = _handle(origin, request)
        .catchError((Object error, StackTrace stack) {
          // Only expected client disconnects after a held response or teardown may
          // be ignored. All other handler errors fail settle()/close().
          final cancellationPossible =
              _closed ||
              (delayManifest && _manifestGate.isCompleted) ||
              (delayMedia && _mediaGate.isCompleted);
          final disconnected =
              error is HttpException &&
                  (error.message == 'Connection closed' ||
                      error.message ==
                          'Connection closed before full header was received') ||
              error is SocketException &&
                  [32, 54, 104].contains(error.osError?.errorCode);
          if (!(cancellationPossible && disconnected)) {
            _handlerErrors.add((error, stack));
          }
        })
        .whenComplete(() => _handlers.remove(handler));
    _handlers.add(handler);
  }

  Future<void> close() async {
    _closed = true;
    releaseDelayedManifest();
    releaseDelayedMedia();
    await Future.wait<void>([
      _primary.close(force: true),
      _secondary.close(force: true),
    ]);
    await settle();
  }

  Future<void> _handle(String origin, HttpRequest request) async {
    _record(origin, request);
    if (request.uri.path == '/redirect.mpd' ||
        request.uri.path == '/redirect-hop.mpd') {
      final first = request.uri.path == '/redirect.mpd';
      request.response.headers.set(
        HttpHeaders.locationHeader,
        _uri(
          first ? _secondary : _primary,
          first ? '/redirect-hop.mpd' : '/manifest.mpd',
        ).toString(),
      );
      await _empty(request.response, HttpStatus.found);
      return;
    }
    if (request.uri.path == '/manifest.mpd' ||
        request.uri.path == '/explicit') {
      if (!_manifestEntered.isCompleted) _manifestEntered.complete();
      if (delayManifest) await _manifestGate.future;
      if (rootStatusCode != null) {
        await _empty(request.response, rootStatusCode!);
        return;
      }
      final bytes = utf8.encode(manifestOverride ?? _servedManifest());
      await _serve(
        request,
        Uint8List.fromList(bytes),
        ContentType('application', 'dash+xml', charset: 'utf-8'),
      );
      return;
    }
    final normalizedPath = request.uri.path.startsWith('/cross/')
        ? request.uri.path.substring('/cross'.length)
        : request.uri.path;
    final bytes = _files[normalizedPath];
    if (bytes == null) {
      await _empty(request.response, HttpStatus.notFound);
      return;
    }
    if (missingMedia && normalizedPath.contains('chunk-0-00001.m4s')) {
      await _empty(request.response, HttpStatus.notFound);
      return;
    }
    if (failMedia && normalizedPath.contains('chunk-0-00001.m4s')) {
      await _empty(request.response, HttpStatus.forbidden);
      return;
    }
    if (delayMedia && normalizedPath.contains('chunk-0-00001.m4s')) {
      if (!_mediaEntered.isCompleted) _mediaEntered.complete();
      await _mediaGate.future;
    }
    await _serve(request, bytes, ContentType('video', 'iso.segment'));
  }

  String _servedManifest() {
    switch (originMode) {
      case DashOriginMode.sameOrigin:
        return _manifest;
      case DashOriginMode.crossOrigin:
        return _manifest
            .replaceAll(
              '<BaseURL>period0/</BaseURL>',
              '<BaseURL>${_uri(_secondary, '/period0/')}</BaseURL>',
            )
            .replaceAll(
              '<BaseURL>period1/</BaseURL>',
              '<BaseURL>${_uri(_secondary, '/period1/')}</BaseURL>',
            );
      case DashOriginMode.returnToPrimary:
        var rewritten = _rewritePeriodForReturn(_manifest, 'period0');
        rewritten = _rewritePeriodForReturn(rewritten, 'period1');
        return rewritten;
    }
  }

  String _rewritePeriodForReturn(String value, String period) {
    final start = value.indexOf('<Period id="$period"');
    final end = value.indexOf('</Period>', start) + '</Period>'.length;
    final original = value.substring(start, end);
    final crossBase = _uri(_secondary, '/cross/');
    final returnBase = _uri(_primary, '/$period/');
    final rewritten = original
        .replaceFirst(
          '<BaseURL>$period/</BaseURL>',
          '<BaseURL>$crossBase</BaseURL>',
        )
        .replaceAllMapped(
          RegExp(r'<AdaptationSet([^>]*)>'),
          (match) => '${match.group(0)}<BaseURL>$returnBase</BaseURL>',
        );
    return value.replaceRange(start, end, rewritten);
  }

  void _record(String origin, HttpRequest request) {
    final headers = <String, List<String>>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = List<String>.unmodifiable(values);
    });
    requests.add(
      RecordedDashRequest(
        origin: origin,
        path: request.uri.path,
        headers: headers,
      ),
    );
  }

  Future<void> _serve(
    HttpRequest request,
    Uint8List bytes,
    ContentType contentType,
  ) async {
    final response = request.response;
    response.headers.contentType = contentType;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    final range = _parseRange(request.headers.value(HttpHeaders.rangeHeader));
    if (range == null) {
      response.statusCode = HttpStatus.ok;
      response.contentLength = bytes.length;
      if (request.method != 'HEAD') response.add(bytes);
    } else {
      final start = range.$1;
      if (start >= bytes.length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${bytes.length}',
        );
        response.contentLength = 0;
      } else {
        final end = range.$2 == null
            ? bytes.length - 1
            : range.$2!.clamp(start, bytes.length - 1);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${bytes.length}',
        );
        response.contentLength = end - start + 1;
        if (request.method != 'HEAD') {
          response.add(bytes.sublist(start, end + 1));
        }
      }
    }
    await response.close();
  }

  Future<void> _empty(HttpResponse response, int status) async {
    response.statusCode = status;
    response.contentLength = 0;
    await response.close();
  }

  static (int, int?)? _parseRange(String? value) {
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(value ?? '');
    if (match == null) return null;
    return (int.parse(match.group(1)!), int.tryParse(match.group(2)!));
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
