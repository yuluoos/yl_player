import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:yl_player/src/iso/iso_image.dart';
import 'package:yl_player/src/iso/iso_server.dart';

// Run from the repository root. One JSON line per cold session, with the
// source's request count, body bytes and elapsed wall time for each phase.
Future<void> main(List<String> args) async {
  final secure = !args.contains('--http');
  final probe = args.where((a) => a.startsWith('--frame-probe=')).firstOrNull;
  final probePath = probe?.substring('--frame-probe='.length);
  final inputs = args.where((a) => a != '--http' && a != probe);
  if (inputs.isEmpty) {
    stderr.writeln(
      'Usage: dart packages/yl_player/tool/iso_ranges.dart [--http] [--frame-probe=<executable>] <movie.iso|fixture.gz.bin> ...',
    );
    exitCode = 64;
    return;
  }
  final temp = await Directory.systemTemp.createTemp('yl-iso-benchmark-');
  try {
    for (final path in inputs) {
      var file = File(path);
      if (path.endsWith('.gz.bin')) {
        final image = File('${temp.path}/fixture.iso');
        await file.openRead().transform(gzip.decoder).pipe(image.openWrite());
        file = image;
      }
      for (var trial = 1; trial <= 3; trial++) {
        await measure(file, path, trial, secure, probePath);
      }
    }
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> measure(
  File file,
  String label,
  int trial,
  bool secure,
  String? probePath,
) async {
  const certs = 'packages/yl_player/test/fixtures/drm_tls';
  final origin = secure
      ? await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          SecurityContext()
            ..useCertificateChain('$certs/server.pem')
            ..usePrivateKey('$certs/server.key'),
        )
      : await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final total = await file.length();
  var requests = 0, bytes = 0;
  origin.listen((request) async {
    final response = request.response;
    final match = RegExp(
      r'^bytes=(\d+)-(\d+)$',
    ).firstMatch(request.headers.value('range') ?? '');
    final first = int.tryParse(match?[1] ?? '') ?? -1;
    final last = int.tryParse(match?[2] ?? '') ?? -1;
    if (first < 0 || first > last || last >= total) {
      response.statusCode = 416;
    } else {
      requests++;
      bytes += last - first + 1;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      response
        ..statusCode = 206
        ..headers.set('content-range', 'bytes $first-$last/$total')
        ..headers.set('etag', '"fixture"')
        ..contentLength = last - first + 1;
      await response.addStream(file.openRead(first, last + 1));
    }
    await response.close();
  });
  final uri = Uri.parse(
    '${secure ? "https" : "http"}://127.0.0.1:${origin.port}/movie.iso',
  );
  final upstream = HttpClient(
    context: secure
        ? (SecurityContext()..setTrustedCertificates('$certs/ca.pem'))
        : null,
  );
  final local = HttpClient();
  final iso = IsoServer(IsoImage.network(uri, {}, {}));
  Future<Uint8List> fetch(Uri uri) async {
    final response = await (await local.getUrl(uri)).close();
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final body = BytesBuilder(copy: false);
    await response.forEach(body.add);
    return body.takeBytes();
  }

  final watch = Stopwatch()..start();
  Map<String, num> sample() => {
    'requests': requests,
    'bytes': bytes,
    'ms': watch.elapsedMicroseconds / 1000,
  };
  try {
    await HttpOverrides.runZoned(iso.open, createHttpClient: (_) => upstream);
    final open = sample();
    if (probePath != null) {
      final probe = await Process.start(probePath, [iso.uri.toString()]);
      final errors = probe.stderr.transform(utf8.decoder).join();
      final phases = <Map<String, num>>[];
      await for (final line
          in probe.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        phases.add({...sample(), 'frameMs': int.parse(line)});
      }
      if (await probe.exitCode != 0 || phases.length != 5) {
        throw StateError('Frame probe failed: ${await errors}');
      }
      stdout.writeln(
        jsonEncode({
          'image': label,
          'scheme': uri.scheme,
          'trial': trial,
          'open': open,
          'firstFrame': phases[0],
          'coldSeek': phases[1],
          'returnSeek': phases[2],
          'repeatSeek': phases[3],
          'finalReturn': phases[4],
        }),
      );
      return;
    }
    final manifest = utf8.decode(await fetch(iso.uri));
    final segments = const LineSplitter()
        .convert(manifest)
        .where((s) => s.endsWith('.ts'))
        .toList();
    final a = iso.uri.resolve(segments.first),
        b = iso.uri.resolve(segments.last);
    await fetch(a);
    final firstSegment = sample();
    requests = 0;
    bytes = 0;
    watch.reset();
    await fetch(b);
    final coldSegment = sample();
    requests = 0;
    bytes = 0;
    watch.reset();
    for (final uri in [a, b, a]) {
      await fetch(uri);
    }
    stdout.writeln(
      jsonEncode({
        'image': label,
        'scheme': uri.scheme,
        'trial': trial,
        'segments': segments.length,
        'open': open,
        'firstSegment': firstSegment,
        'coldSegment': coldSegment,
        'revisits': sample(),
      }),
    );
  } finally {
    local.close(force: true);
    // AVPlayer can exit while its final HLS segment is being served. Let
    // outstanding origin responses drain before disposing the ISO session.
    upstream.close();
    final drain = Stopwatch()..start();
    while (origin.connectionsInfo().total != 0 &&
        drain.elapsed < const Duration(seconds: 20)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await iso.close();
    await origin.close(force: true);
  }
}
