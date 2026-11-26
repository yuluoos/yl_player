import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'udf.dart';

final class IsoRangeException implements Exception {
  const IsoRangeException();
}

/// Random access with a small metadata cache. Media is read on demand.
final class IsoImage {
  IsoImage.file(String path) : _file = File(path), _uri = null;
  IsoImage.network(Uri uri, this._headers, this._credentials)
    : _file = null,
      _uri = uri;
  final File? _file;
  Uri? _uri;
  Map<String, String> _headers = const {}, _credentials = const {};
  final _pages = <int, Uint8List>{};
  RandomAccessFile? _handle;
  Future<void> _fileQueue = Future.value();
  HttpClient? _client;
  int length = 0;
  bool _closed = false;
  String? _validator;
  bool _usesEtag = false;
  static const _page = 32768;
  Future<void> open() async {
    if (_closed) throw const HttpException('Closed image');
    if (_file != null) {
      final f = await _file.open();
      if (_closed) {
        await f.close();
        throw const HttpException('Closed image');
      }
      _handle = f;
      length = await f.length();
    } else {
      _client = HttpClient()
        ..autoUncompress = false
        ..connectionTimeout = const Duration(seconds: 15)
        ..maxConnectionsPerHost = 4;
      await _network(0, 1);
    }
  }

  Future<Uint8List> read(int offset, int count) async {
    if (_closed || offset < 0 || count < 0 || offset > length - count) {
      invalidDisc();
    }
    if (count == 0) return Uint8List(0);
    final page = offset ~/ _page;
    if (count <= 4096 && (offset + count - 1) ~/ _page == page) {
      final at = page * _page;
      final bytes =
          _pages.remove(page) ?? await _read(at, (length - at).clamp(0, _page));
      if (_pages.length >= 16) _pages.remove(_pages.keys.first);
      _pages[page] = bytes;
      return Uint8List.sublistView(bytes, offset - at, offset - at + count);
    }
    return _read(offset, count);
  }

  Future<Uint8List> _read(int offset, int count) {
    if (_file == null) return _network(offset, count);
    final task = _fileQueue.then((_) async {
      final handle = _handle;
      if (handle == null || _closed) invalidDisc();
      await handle.setPosition(offset);
      final bytes = await handle.read(count);
      if (bytes.length != count) invalidDisc();
      return bytes;
    });
    _fileQueue = task.then<void>((_) {}, onError: (Object _) {});
    return task;
  }

  Future<Uint8List> _network(int offset, int count) async {
    final end = offset + count - 1;
    var uri = _uri!;
    for (var hop = 0; hop <= 5; hop++) {
      final client = _client;
      if (client == null || _closed) throw const HttpException('Closed image');
      final request = await client.getUrl(uri);
      final deadline = Timer(
        const Duration(seconds: 20),
        () => request.abort(const HttpException('Response timeout')),
      );
      HttpClientResponse response;
      try {
        request.followRedirects = false;
        _headers.forEach(request.headers.set);
        _credentials.forEach(request.headers.set);
        request.headers.set('accept-encoding', 'identity');
        request.headers.set('range', 'bytes=$offset-$end');
        if (_validator != null) request.headers.set('if-range', _validator!);
        response = await request.close();
      } finally {
        deadline.cancel();
      }
      if (response.isRedirect) {
        final location = response.headers.value('location');
        await response.listen(null).cancel();
        if (location == null || hop == 5) {
          throw const HttpException('Invalid image redirect');
        }
        final next = uri.resolve(location);
        if (!{'http', 'https'}.contains(next.scheme) ||
            next.host.isEmpty ||
            next.userInfo.isNotEmpty ||
            uri.scheme == 'https' && next.scheme != 'https') {
          throw const HttpException('Invalid image redirect');
        }
        if (next.origin != uri.origin) _credentials = const {};
        uri = next;
        continue;
      }
      final range = response.headers.value('content-range');
      final match = RegExp(
        r'^bytes (\d+)-(\d+)/(\d{1,16})$',
      ).firstMatch(range ?? '');
      final size = match == null ? null : int.tryParse(match[3]!);
      final encoding = response.headers.value('content-encoding');
      if (response.statusCode == 401 ||
          response.statusCode == 403 ||
          response.statusCode >= 400 && response.statusCode != 416) {
        await response.listen(null).cancel();
        throw const HttpException('Image request failed');
      }
      if (response.statusCode != 206 ||
          size == null ||
          size <= end ||
          match![1] != '$offset' ||
          match[2] != '$end' ||
          length != 0 && length != size ||
          encoding != null && encoding.toLowerCase() != 'identity' ||
          response.contentLength >= 0 && response.contentLength != count) {
        await response.listen(null).cancel();
        throw const IsoRangeException();
      }
      final etag = response.headers.value('etag');
      final modified = response.headers.value('last-modified');
      if (length == 0) {
        _usesEtag = etag != null && etag.startsWith('"');
        _validator = _usesEtag ? etag : modified;
      } else if (_validator != null &&
          (_usesEtag ? etag : modified) != _validator) {
        await response.listen(null).cancel();
        throw const IsoRangeException();
      }
      length = size;
      _uri = uri;
      final body = BytesBuilder(copy: false);
      await for (final bytes in response.timeout(const Duration(seconds: 20))) {
        if (body.length + bytes.length > count) throw const IsoRangeException();
        body.add(bytes);
      }
      if (body.length != count) throw const IsoRangeException();
      return body.takeBytes();
    }
    throw const HttpException('Too many image redirects');
  }

  Future<void> close() async {
    _closed = true;
    _client?.close(force: true);
    _client = null;
    await _fileQueue;
    final handle = _handle;
    _handle = null;
    await handle?.close();
    _pages.clear();
  }
}
