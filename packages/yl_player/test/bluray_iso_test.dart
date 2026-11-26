import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/iso/iso_image.dart';
import 'package:yl_player/src/iso/iso_input.dart';
import 'package:yl_player/src/iso/iso_server.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'support/fake_player_platform.dart';

Future<Uint8List> fetch(HttpClient client, Uri uri, {String? range}) async {
  final request = await client.getUrl(uri);
  if (range != null) request.headers.set('range', range);
  final response = await request.close();
  expect(response.statusCode, range == null ? 200 : 206);
  final body = BytesBuilder();
  await for (final chunk in response) {
    body.add(chunk);
  }
  return body.takeBytes();
}

class _CapturePlayer extends FakePlatformPlayer {
  final nativeSource = Completer<YlNetworkSource>();
  @override
  Future<YlPlatformLoadResult> load(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) {
    nativeSource.complete(source as YlNetworkSource);
    return super.load(source, options: options);
  }
}

void main() {
  test(
    'A failed replacement preserves an ISO already admitted by native playback',
    () async {
      final temp = await Directory.systemTemp.createTemp('yl-session-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/movie.iso');
      await file.writeAsBytes(
        gzip.decode(
          await File(
            'example/assets/test_media/bluray_colors.iso.gz.bin',
          ).readAsBytes(),
        ),
      );
      final backend = _CapturePlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      addTearDown(player.dispose);
      final original = player.load(YlFileSource(file.path));
      final native = await backend.nativeSource.future;
      final cancelled = expectLater(
        original,
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.loadCancelled,
          ),
        ),
      );
      final replacement = player.load(YlFileSource('${temp.path}/missing.iso'));
      backend.commit(const YlPlaybackSessionId('disc'));
      await expectLater(
        replacement,
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.sourceMissing,
          ),
        ),
      );
      await cancelled;
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      expect(
        utf8.decode(await fetch(client, native.uri)),
        contains('#EXT-X-ENDLIST'),
      );
      await player.stop();
      await expectLater(fetch(client, native.uri), throwsA(isA<IOException>()));
    },
  );
  test(
    'A real UDF 2.50 image yields identical local and authenticated HTTPS titles',
    () async {
      final raw = gzip.decode(
        await File(
          'example/assets/test_media/bluray_colors.iso.gz.bin',
        ).readAsBytes(),
      );
      final tmp = await Directory.systemTemp.createTemp('disc-test');
      addTearDown(() => tmp.delete(recursive: true));
      final file = await File('${tmp.path}/movie.iso').writeAsBytes(raw);
      final tls = SecurityContext()
        ..useCertificateChain('test/fixtures/drm_tls/server.pem')
        ..usePrivateKey('test/fixtures/drm_tls/server.key');
      final trust = SecurityContext()
        ..setTrustedCertificates('test/fixtures/drm_tls/ca.pem');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        tls,
      );
      addTearDown(() => server.close(force: true));
      final ranges = <String>[];
      server.listen((r) async {
        expect(r.headers.value('authorization'), 'Bearer iso-test');
        final range = r.headers.value('range')!;
        ranges.add(range);
        final span = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(span[1]!), end = int.parse(span[2]!);
        r.response
          ..statusCode = 206
          ..headers.set('content-range', 'bytes $start-$end/${raw.length}')
          ..headers.set('etag', '"v1"')
          ..add(raw.sublist(start, end + 1));
        await r.response.close();
      });
      // Construct clients outside the override to avoid recursive creation.
      final direct = HttpClient();
      addTearDown(() => direct.close(force: true));
      final upstream = HttpClient(context: trust);
      final local = IsoServer(IsoImage.file(file.path));
      final remote = IsoServer(
        IsoImage.network(
          Uri.parse('https://127.0.0.1:${server.port}/movie.iso'),
          {},
          {'Authorization': 'Bearer iso-test'},
        ),
      );
      addTearDown(local.close);
      addTearDown(remote.close);
      await local.open();
      await HttpOverrides.runZoned(
        () => remote.open(playlist: 0),
        createHttpClient: (_) => upstream,
      );
      final manifest = utf8.decode(await fetch(direct, local.uri));
      expect(utf8.decode(await fetch(direct, remote.uri)), manifest);
      expect('#EXT-X-DISCONTINUITY'.allMatches(manifest).length, 2);
      final segments = manifest
          .split('\n')
          .where((s) => s.endsWith('.ts'))
          .toList();
      expect(segments.length, greaterThan(3));
      for (final name in segments) {
        final bytes = await fetch(direct, local.uri.resolve(name));
        expect(await fetch(direct, remote.uri.resolve(name)), bytes);
        expect(bytes.length % 188, 0);
        expect(
          await fetch(direct, remote.uri.resolve(name), range: 'bytes=187-377'),
          bytes.sublist(187, 378),
        );
      }
      expect(ranges.first, 'bytes=0-0');
      expect(ranges, isNot(contains('bytes=0-${raw.length - 1}')));
    },
  );
  test(
    'HTTP 200 and inconsistent Content-Range fail before the backend receives a source',
    () async {
      for (final status in [200, 206]) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((r) async {
          r.response
            ..statusCode = status
            ..headers.set('content-range', 'bytes 2-2/4000000')
            ..add([0]);
          await r.response.close();
        });
        final input = createIsoInput(
          YlNetworkSource(
            Uri.parse('http://127.0.0.1:${server.port}/movie.iso'),
          ),
          const YlLoadOptions(),
        );
        addTearDown(input.close);
        await expectLater(
          input.open(null),
          throwsA(
            isA<YlPlayerException>().having(
              (e) => e.failure.code,
              'code',
              YlFailureCodes.networkIsoRangeUnavailable,
            ),
          ),
        );
      }
    },
  );
  test(
    'Range reads strip credentials across redirects and reject a changed image',
    () async {
      final destination = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => destination.close(force: true));
      var reads = 0;
      destination.listen((r) async {
        expect(r.headers.value('authorization'), isNull);
        expect(r.headers.value('x-disc'), 'seen');
        final probe = reads++ == 0;
        expect(r.headers.value('if-range'), probe ? isNull : '"a"');
        r.response
          ..statusCode = 206
          ..headers.set('content-range', probe ? 'bytes 0-0/2' : 'bytes 0-1/2')
          ..headers.set('etag', probe ? '"a"' : '"b"')
          ..add(probe ? [0] : [0, 1]);
        await r.response.close();
      });
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      origin.listen((r) async {
        expect(r.headers.value('authorization'), 'Bearer private');
        await r.response.redirect(
          Uri.parse('http://127.0.0.1:${destination.port}/media'),
        );
      });
      final image = IsoImage.network(
        Uri.parse('http://127.0.0.1:${origin.port}/movie.iso'),
        {'X-Disc': 'seen'},
        {'Authorization': 'Bearer private'},
      );
      addTearDown(image.close);
      await image.open();
      await expectLater(image.read(1, 1), throwsA(isA<IsoRangeException>()));
      expect(reads, 2);
    },
  );
}
