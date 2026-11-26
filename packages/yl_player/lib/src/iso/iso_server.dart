import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'bluray_title.dart';
import 'dvd_title.dart';
import 'iso_image.dart';
import 'iso_segment.dart';
import 'udf.dart';

/// Owns the virtual VOD title and its image for exactly one playback session.
final class IsoServer {
  IsoServer(this.image);
  final IsoImage image;
  HttpServer? _server;
  DvdSegmentCache? _dvdCache;
  bool _closed = false;
  int _active = 0;
  late final Uri uri;
  Future<void> open({int? playlist, int? dvdTitle}) async {
    await image.open();
    final volume = await UdfVolume.open(image.read, image.length);
    final root = await volume.directory(volume.root);
    final dvd = root['VIDEO_TS'];
    final List<IsoSegment> segments;
    final isDvd =
        dvdTitle != null ||
        (playlist == null && dvd != null && !root.containsKey('BDMV'));
    if (isDvd) {
      if (dvd == null || playlist != null) invalidDisc();
      segments = await openDvdTitle(volume, dvd, number: dvdTitle);
    } else {
      segments = await openMainTitle(volume, playlist: playlist);
    }
    final cache = _dvdCache = isDvd ? DvdSegmentCache() : null;
    Future<IsoPayload> payload(int index) =>
        cache?.get(index, segments[index]) ?? segments[index].openPayload();

    // Validate the first playable DVD segment and reuse it on the first GET.
    if (isDvd) await payload(0);
    final maxTicks = segments.map((s) => s.ticks).reduce(max);
    final manifest = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:3')
      ..writeln('#EXT-X-TARGETDURATION:${(maxTicks + 44999) ~/ 45000}')
      ..writeln('#EXT-X-PLAYLIST-TYPE:VOD');
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      if (s.discontinuity) manifest.writeln('#EXT-X-DISCONTINUITY');
      manifest
        ..writeln('#EXTINF:${(s.ticks / 45000).toStringAsFixed(6)},')
        ..writeln('$i.ts');
    }
    manifest.writeln('#EXT-X-ENDLIST');
    final bytes = Uint8List.fromList(utf8.encode(manifest.toString()));
    final random = Random.secure();
    final prefix =
        '/${base64Url.encode(List.generate(24, (_) => random.nextInt(256)))}/';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw const HttpException('Closed title');
    }
    _server = server;
    uri = Uri.parse('http://127.0.0.1:${server.port}${prefix}main.m3u8');
    server.listen((request) async {
      final response = request.response;
      _active++;
      try {
        if (_active > 12) {
          response.statusCode = 503;
          return;
        }
        if (request.method != 'GET' && request.method != 'HEAD') {
          response.statusCode = 405;
          return;
        }
        final path = request.uri.path;
        if (!path.startsWith(prefix)) {
          response.statusCode = 404;
          return;
        }
        final name = path.substring(prefix.length);
        final isManifest = name == 'main.m3u8';
        final match = RegExp(r'^(\d{1,6})\.ts$').firstMatch(name);
        final index = int.tryParse(match?[1] ?? '') ?? -1;
        if (!isManifest && (index < 0 || index >= segments.length)) {
          response.statusCode = 404;
          return;
        }
        final media = isManifest ? null : await payload(index);
        final length = media?.length ?? bytes.length;
        var start = 0, stop = length;
        response.headers.set('accept-ranges', 'bytes');
        final range = request.headers.value('range');
        if (range != null) {
          final bounds = RegExp(
            r'^bytes=(\d{1,16})-(\d{0,16})$',
          ).firstMatch(range);
          start = int.tryParse(bounds?[1] ?? '') ?? -1;
          final last = int.tryParse(bounds?[2] ?? '');
          if (last != null) stop = (last + 1).clamp(0, length);
          if (start < 0 || start >= stop) {
            response.statusCode = 416;
            response.headers.set('content-range', 'bytes */$length');
            return;
          }
          response.statusCode = 206;
          response.headers.set(
            'content-range',
            'bytes $start-${stop - 1}/$length',
          );
        }
        response.headers.set(
          'content-type',
          isManifest ? 'application/vnd.apple.mpegurl' : 'video/mp2t',
        );
        response.contentLength = stop - start;
        if (request.method == 'HEAD') return;
        if (isManifest) {
          response.add(Uint8List.sublistView(bytes, start, stop));
        } else {
          await response.addStream(media!.read(start, stop));
        }
      } catch (_) {
        // Partial media responses must terminate early, never pad a failed read.
        try {
          response.statusCode = 502;
        } catch (_) {}
      } finally {
        try {
          await response.close();
        } catch (_) {}
        _active--;
      }
    });
  }

  Future<void>? _closing;
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _dvdCache?.close();
    await Future.wait([
      if (_server != null) _server!.close(force: true),
      image.close(),
    ]);
  }
}
