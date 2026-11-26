import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/iso/bluray_title.dart';
import 'package:yl_player/src/iso/iso_image.dart';
import 'package:yl_player/src/iso/iso_input.dart';
import 'package:yl_player/src/iso/iso_server.dart';
import 'package:yl_player/src/iso/udf.dart';
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

// Each authored PES header fits in its first TS packet. Hash the elementary
// streams independently of the ISO parser and TS writer.
(int, int) _elementarySignature(List<Uint8List> segments, int pid) {
  var length = 0, a = 1, b = 0;
  for (final bytes in segments) {
    for (var off = 0; off < bytes.length; off += 188) {
      expect(bytes[off], 0x47);
      final packetId = ((bytes[off + 1] & 31) << 8) | bytes[off + 2];
      final flags = bytes[off + 3];
      if (packetId != pid || flags & 0x10 == 0) continue;
      var at = off + 4;
      if (flags & 0x20 != 0) at += bytes[at] + 1;
      if (bytes[off + 1] & 0x40 != 0) {
        expect(bytes.sublist(at, at + 3), [0, 0, 1]);
        at += 9 + bytes[at + 8];
      }
      for (; at < off + 188; at++) {
        a = (a + bytes[at]) % 65521;
        b = (b + a) % 65521;
        length++;
      }
    }
  }
  return (length, (b << 16) | a);
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
  final packageDir = Directory('packages/yl_player');
  final root = packageDir.existsSync() ? packageDir : Directory.current;
  String fixture(String relative) => root.uri.resolve(relative).toFilePath();
  test(
    'A failed replacement preserves an ISO already admitted by native playback',
    () async {
      final temp = await Directory.systemTemp.createTemp('yl-session-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/movie.iso');
      await file.writeAsBytes(
        gzip.decode(
          await File(
            fixture('example/assets/test_media/bluray_colors.iso.gz.bin'),
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
  for (final dvd in [false, true]) {
    test(
      '${dvd ? 'DVD' : 'Blu-ray'} ISO yields identical local and authenticated HTTPS titles',
      () async {
        final raw = gzip.decode(
          await File(
            fixture(
              'example/assets/test_media/${dvd ? 'dvd_titles' : 'bluray_colors'}.iso.gz.bin',
            ),
          ).readAsBytes(),
        );
        final tmp = await Directory.systemTemp.createTemp('disc-test');
        addTearDown(() => tmp.delete(recursive: true));
        final file = await File('${tmp.path}/movie.iso').writeAsBytes(raw);
        final tls = SecurityContext()
          ..useCertificateChain(fixture('test/fixtures/drm_tls/server.pem'))
          ..usePrivateKey(fixture('test/fixtures/drm_tls/server.key'));
        final trust = SecurityContext()
          ..setTrustedCertificates(fixture('test/fixtures/drm_tls/ca.pem'));
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
          () => dvd ? remote.open(dvdTitle: 2) : remote.open(playlist: 0),
          createHttpClient: (_) => upstream,
        );
        // The cold path used to issue 14 DVD or 11 Blu-ray requests here.
        expect(ranges.length, lessThanOrEqualTo(dvd ? 10 : 8));
        final manifest = utf8.decode(await fetch(direct, local.uri));
        expect(utf8.decode(await fetch(direct, remote.uri)), manifest);
        expect('#EXT-X-DISCONTINUITY'.allMatches(manifest).length, dvd ? 1 : 2);
        final segments = manifest
            .split('\n')
            .where((s) => s.endsWith('.ts'))
            .toList();
        expect(segments.length, greaterThan(3));
        if (!dvd) {
          // Skip the second clip's opening segment to take the cold seek path.
          final target = manifest
              .split('#EXT-X-DISCONTINUITY')[1]
              .split('\n')
              .where((s) => s.endsWith('.ts'))
              .elementAt(1);
          expect(
            await fetch(direct, remote.uri.resolve(target), range: 'bytes=0-'),
            await fetch(direct, local.uri.resolve(target)),
          );
        }
        final dvdBytes = <Uint8List>[];
        for (final name in segments) {
          final bytes = await fetch(direct, local.uri.resolve(name));
          expect(await fetch(direct, remote.uri.resolve(name)), bytes);
          expect(bytes.length % 188, 0);
          if (dvd) dvdBytes.add(bytes);
          expect(
            await fetch(
              direct,
              remote.uri.resolve(name),
              range: 'bytes=187-377',
            ),
            bytes.sublist(187, 378),
          );
        }
        if (dvd) {
          final before = ranges.length;
          for (final index in [0, segments.length - 1, 0]) {
            final uri = remote.uri.resolve(segments[index]);
            final head = await (await direct.headUrl(uri)).close();
            expect(head.contentLength, dvdBytes[index].length);
            await head.drain<void>();
            expect(
              await fetch(direct, uri, range: 'bytes=187-377'),
              dvdBytes[index].sublist(187, 378),
            );
          }
          expect(ranges.length, before);
          // FFmpeg stream-copy of the authored VOB cells in title order.
          expect(_elementarySignature(dvdBytes, 256), (88536, 0x617c977a));
          expect(_elementarySignature(dvdBytes, 257), (336384, 0xf9b89104));
        }
        expect(ranges.first, 'bytes=0-0');
        expect(ranges, isNot(contains('bytes=0-${raw.length - 1}')));
      },
    );
  }
  test(
    'cold Blu-ray full GET overlaps program and media reads exactly once',
    () async {
      final bytes = Uint8List.fromList(
        gzip.decode(
          await File(
            fixture('example/assets/test_media/bluray_colors.iso.gz.bin'),
          ).readAsBytes(),
        ),
      );
      final release = Completer<void>(), mediaStarted = Completer<void>();
      final reads = <(int, int)>[];
      var holdTables = false, failTableRead = false;
      final volume = await UdfVolume.open((
        int offset,
        int length, {
        bool readAhead = true,
      }) async {
        if (holdTables) {
          reads.add((offset, length));
          if (length == 16 * 192) {
            if (failTableRead) {
              throw const HttpException('Interrupted table read');
            }
            await release.future;
          } else if (!mediaStarted.isCompleted) {
            mediaStarted.complete();
          }
        }
        return Uint8List.sublistView(bytes, offset, offset + length);
      }, bytes.length);
      final segments = await openMainTitle(volume);
      final target = segments.indexWhere((s) => s.discontinuity) + 1;
      expect(target, greaterThan(1));
      expect(segments[target].discontinuity, isFalse);
      // A separate title instance gives us the original sequential byte stream.
      final reference = await openMainTitle(volume);
      final original = await reference[target].openPayload();
      final expected = await original
          .read(0, original.length)
          .expand((b) => b)
          .toList();
      holdTables = true;
      final opening = segments[target].openPayload(fullNetworkRead: true);
      try {
        await mediaStarted.future.timeout(const Duration(seconds: 3));
        expect(reads, hasLength(2));
        expect(reads.first.$2, 16 * 192);
        expect(reads.last.$2, lessThanOrEqualTo(2048 * 192));
      } finally {
        release.complete();
      }
      final payload = await opening;
      expect(
        await payload.read(0, payload.length).expand((b) => b).toList(),
        expected,
      );
      expect(reads, hasLength(2));

      // A HEAD opens the payload without fetching media. A prefix-only Range
      // can then be answered from the same tables.
      holdTables = false;
      final fresh = await openMainTitle(volume);
      reads.clear();
      holdTables = true;
      final probe = await fresh[target].openPayload();
      expect(probe.length, expected.length);
      expect(
        await probe.read(0, 2).expand((b) => b).toList(),
        expected.take(2),
      );
      expect(reads.map((r) => r.$2), [16 * 192]);

      // A failed parallel read must leave the clip available for another seek.
      holdTables = false;
      final retry = await openMainTitle(volume);
      holdTables = true;
      failTableRead = true;
      await expectLater(
        retry[target].openPayload(fullNetworkRead: true),
        throwsA(isA<HttpException>()),
      );
      failTableRead = false;
      final recovered = await retry[target].openPayload(fullNetworkRead: true);
      expect(
        await recovered.read(0, recovered.length).expand((b) => b).toList(),
        expected,
      );
    },
  );
  test(
    'Blu-ray accepts program tables beyond the short startup probe',
    () async {
      final bytes = Uint8List.fromList(
        gzip.decode(
          await File(
            fixture('example/assets/test_media/bluray_colors.iso.gz.bin'),
          ).readAsBytes(),
        ),
      );
      var offset = 0;
      final volume = await UdfVolume.open((
        int at,
        int length, {
        bool readAhead = true,
      }) async {
        offset = at;
        return Uint8List.sublistView(bytes, at, at + length);
      }, bytes.length);
      final root = await volume.directory(volume.root);
      final bd = await volume.directory(await volume.child(root, 'BDMV'));
      final streams = await volume.directory(await volume.child(bd, 'STREAM'));
      final clip = await volume.child(streams, '00000.M2TS');
      const prefixSize = 16 * 192;
      final prefix = Uint8List.fromList(await clip.read(0, prefixSize));
      // Move the original PAT/PMT and replace their first packets with null TS.
      bytes.setRange(offset + prefixSize, offset + 2 * prefixSize, prefix);
      for (var i = offset + 4; i < offset + prefixSize; i += 192) {
        bytes.setAll(i, [0x47, 0x1f, 0xff, 0x10]);
      }
      final tmp = await Directory.systemTemp.createTemp('bd-program-tables-');
      addTearDown(() => tmp.delete(recursive: true));
      final file = await File('${tmp.path}/movie.iso').writeAsBytes(bytes);
      final server = IsoServer(IsoImage.file(file.path));
      addTearDown(server.close);
      await server.open();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final segment = await fetch(client, server.uri.resolve('1.ts'));
      // A segment starting mid-clip has the recovered PAT as its first packet.
      expect(segment.sublist(0, 3), [0x47, 0x40, 0]);
    },
  );
  test(
    'DVD title 1 selects only the short title and missing titles fail',
    () async {
      final temp = await Directory.systemTemp.createTemp('dvd-selection-');
      addTearDown(() => temp.delete(recursive: true));
      final raw = gzip.decode(
        await File(
          fixture('example/assets/test_media/dvd_titles.iso.gz.bin'),
        ).readAsBytes(),
      );
      final f = await File('${temp.path}/movie.iso').writeAsBytes(raw);
      final local = IsoServer(IsoImage.file(f.path));
      addTearDown(local.close);
      await local.open(dvdTitle: 1);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final manifest = utf8.decode(await fetch(client, local.uri));
      final ticks = RegExp(r'#EXTINF:([0-9.]+),')
          .allMatches(manifest)
          .fold(0.0, (total, match) => total + double.parse(match[1]!));
      expect(ticks, closeTo(7.007, 0.001));
      expect(manifest, isNot(contains('#EXT-X-DISCONTINUITY')));
      final missing = createIsoInput(
        YlFileSource(f.path),
        const YlLoadOptions(),
      );
      addTearDown(missing.close);
      await expectLater(
        missing.open(null, dvdTitle: 3),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.containerUnsupported,
          ),
        ),
      );
    },
  );
  test(
    'A scrambled DVD video PES is rejected before creating a playback URL',
    () async {
      final tmp = await Directory.systemTemp.createTemp('disc-scrambling-');
      addTearDown(() => tmp.delete(recursive: true));
      final raw = gzip.decode(
        await File(
          fixture('example/assets/test_media/dvd_titles.iso.gz.bin'),
        ).readAsBytes(),
      );
      var changed = 0;
      for (var i = 0; i + 7 < raw.length; i++) {
        if (raw[i] == 0 &&
            raw[i + 1] == 0 &&
            raw[i + 2] == 1 &&
            raw[i + 3] == 0xe0 &&
            raw[i + 6] & 0xc0 == 0x80) {
          raw[i + 6] |= 0x10;
          changed++;
        }
      }
      expect(changed, greaterThan(0));
      final image = await File('${tmp.path}/scrambled.iso').writeAsBytes(raw);
      final input = createIsoInput(
        YlFileSource(image.path),
        const YlLoadOptions(),
      );
      addTearDown(input.close);
      await expectLater(
        input.open(null),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.containerUnsupported,
          ),
        ),
      );
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
