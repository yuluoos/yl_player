import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/dash_subtitle_resource.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'package:yl_player/yl_player.dart';

void main() {
  late SubtitleCancellation token;
  setUp(() => token = SubtitleCancellation());
  tearDown(() => token.cancel());
  Future<HttpServer> serve(void Function(HttpRequest) handle) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handle);
    addTearDown(() => server.close(force: true));
    return server;
  }

  Uri uri(HttpServer server, String path) =>
      Uri.parse('http://127.0.0.1:${server.port}$path');
  YlNetworkSource source(Uri uri, {int retries = 1}) => YlNetworkSource(
    uri,
    format: YlMediaFormat.dash,
    request: YlHttpRequest(
      headers: {'X-Public': 'ordinary'},
      credentials: {'X-Key': 'secret'},
    ),
    networkPolicy: YlNetworkPolicy.managed(
      maxRetries: retries,
      maxRedirects: 4,
      baseRetryDelay: Duration.zero,
      maxRetryDelay: Duration.zero,
    ),
  );
  Matcher failed(String code) => throwsA(
    isA<YlPlayerException>().having((e) => e.failure.code, 'code', code),
  );

  test('root redirects and BaseURL return keep credentials stripped', () async {
    final observed = <String, String?>{};
    late HttpServer primary;
    final foreign = await serve((r) {
      observed['foreign'] = r.headers.value('X-Key');
      r.response.statusCode = 302;
      r.response.headers.set('location', uri(primary, '/returned.mpd'));
      unawaited(r.response.close());
    });
    primary = await serve((r) {
      observed[r.uri.path] = r.headers.value('X-Key');
      expect(r.headers.value('X-Public'), 'ordinary');
      if (r.uri.path == '/root.mpd') {
        r.response.statusCode = 302;
        r.response.headers.set('location', uri(foreign, '/foreign.mpd'));
      } else {
        r.response.write('owned');
      }
      unawaited(r.response.close());
    });
    final reader = createDashSubtitleReader(source(uri(primary, '/root.mpd')));
    final root = await reader.root(token);
    expect(root.location.uri, uri(primary, '/returned.mpd'));
    expect(root.location.credentialsStripped, isTrue);
    final child = root.location.resolve('child.vtt');
    expect(
      utf8.decode(
        (await reader.read(DashSubtitleResource([child]), token, 1024)).bytes,
      ),
      'owned',
    );
    expect(observed, {
      '/root.mpd': 'secret',
      'foreign': null,
      '/returned.mpd': null,
      '/child.vtt': null,
    });
  });
  test(
    'BaseURL alternatives share one retry allowance across repeated reads',
    () async {
      final seen = <String>[];
      var healthy = true;
      final server = await serve((r) {
        seen.add(r.uri.path);
        if (r.uri.path == '/a.vtt' || !healthy) {
          r.response.statusCode = 503;
        } else {
          r.response.write('WEBVTT');
        }
        unawaited(r.response.close());
      });
      final reader = createDashSubtitleReader(source(uri(server, '/root.mpd')));
      final resource = DashSubtitleResource([
        DashSubtitleLocation(uri(server, '/a.vtt')),
        DashSubtitleLocation(uri(server, '/b.vtt')),
      ]);
      expect(
        utf8.decode((await reader.read(resource, token, 100)).bytes),
        'WEBVTT',
      );
      expect(seen, ['/a.vtt', '/b.vtt']);
      healthy = false;
      await expectLater(
        reader.read(resource, token, 100),
        failed(YlFailureCodes.networkFailed),
      );
      expect(seen, ['/a.vtt', '/b.vtt', '/b.vtt']);
    },
  );
  test(
    'range replies must match exact interval and retain resource validator',
    () async {
      final ranges = <String?>[];
      var changed = false;
      final server = await serve((r) {
        ranges.add(r.headers.value('range'));
        r.response.statusCode = 206;
        r.response.headers.set('content-range', 'bytes 4-7/12');
        r.response.headers.set('etag', changed ? '"changed"' : '"owned"');
        r.response.add([4, 5, 6, 7]);
        unawaited(r.response.close());
      });
      final reader = createDashSubtitleReader(source(uri(server, '/root.mpd')));
      final resource = DashSubtitleResource([
        DashSubtitleLocation(uri(server, '/sub.mp4')),
      ], range: const DashSubtitleRange(4, 4));
      final reply = await reader.read(resource, token, 100);
      expect(reply.bytes, [4, 5, 6, 7]);
      expect(reply.sourceOffset, 4);
      changed = true;
      await expectLater(
        reader.read(resource, token, 100),
        failed(YlFailureCodes.subtitleUnsupported),
      );
      expect(ranges, ['bytes=4-7', 'bytes=4-7']);
    },
  );
  test(
    'cancellation stops delayed body and never retries cancelled work',
    () async {
      final arrived = Completer<void>();
      var count = 0;
      final server = await serve((r) {
        count++;
        arrived.complete();
      });
      final reader = createDashSubtitleReader(source(uri(server, '/root.mpd')));
      final work = reader.root(token);
      final rejected = expectLater(work, failed(YlFailureCodes.loadCancelled));
      await arrived.future;
      token.cancel();
      await rejected;
      expect(count, 1);
    },
  );
}
