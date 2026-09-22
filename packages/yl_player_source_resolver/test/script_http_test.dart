import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_source_resolver/yl_player_source_resolver.dart';

Matcher code(String value) =>
    isA<YlScriptException>().having((e) => e.code, 'code', value);
void main() {
  late HttpServer a, b;
  late YlScriptResolver resolver;
  setUp(() async {
    a = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    b = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    resolver = YlScriptResolver();
  });
  tearDown(() async {
    await resolver.dispose();
    await a.close(force: true);
    await b.close(force: true);
  });
  String url(HttpServer s, [String p = '']) => 'http://127.0.0.1:${s.port}/$p';
  test('sync HTTP method contracts and exact post bytes', () async {
    final bodies = <String>[];
    a.listen((r) async {
      bodies.add(await utf8.decoder.bind(r).join());
      r.response.write('https://fixture.invalid/${r.method}');
      await r.response.close();
    });
    for (final m in ['get', 'fetch', 'post', 'request']) {
      final args = m == 'post'
          ? ',["Content-Length: 2"],"{}"'
          : m == 'request'
          ? ',"GET",[]'
          : '';
      final result = await resolver
          .resolveSource(
            'function main(){const r=mytv.$m("${url(a)}"$args);return {url:${m == 'request' ? 'r.body' : 'r'}}}',
          )
          .result;
      expect(result.uri.path, m == 'post' ? '/POST' : '/GET');
    }
    expect(bodies, ['', '', '{}', '']);
  });
  test('sticky A B A strip and same-origin retention', () async {
    final seen = <String?>[];
    a.listen((r) async {
      seen.add(r.headers.value('x-secret'));
      if (r.uri.path == '/start') {
        r.response.statusCode = 302;
        r.response.headers.set('location', url(b));
      } else if (r.uri.path == '/same') {
        r.response.statusCode = 302;
        r.response.headers.set('location', '/end');
      } else {
        r.response.write('https://fixture.invalid');
      }
      await r.response.close();
    });
    b.listen((r) async {
      seen.add(r.headers.value('x-secret'));
      r.response.statusCode = 302;
      r.response.headers.set('location', url(a, 'end'));
      await r.response.close();
    });
    for (final p in ['start', 'same']) {
      await resolver
          .resolveSource(
            'function main(){return {url:mytv.get("${url(a, p)}",["X-Secret: token"])}}',
          )
          .result;
    }
    expect(seen, ['token', null, null, 'token', 'token']);
  });
  test('request exposes status but get HTTP failure is fatal', () async {
    var count = 0;
    a.listen((r) async {
      count++;
      r.response.statusCode = 403;
      r.response.write('SECRET');
      await r.response.close();
    });
    expect(
      (await resolver
              .resolveSource(
                'function main(){const r=mytv.request("${url(a)}","GET",[]);return {url:"https://fixture.invalid/"+r.code}}',
              )
              .result)
          .uri
          .path,
      '/403',
    );
    await expectLater(
      resolver
          .resolveSource(
            'function main(){try{mytv.get("${url(a)}")}catch(e){}return {url:"https://fixture.invalid"}}',
          )
          .result,
      throwsA(code('script.http_forbidden')),
    );
    expect(count, 2);
  });
  test('count and decompressed response bounds', () async {
    var count = 0;
    a.listen((r) async {
      count++;
      if (r.uri.path == '/big') {
        r.response.headers.set('content-encoding', 'gzip');
        r.response.add(gzip.encode(List.filled(1048577, 65)));
      } else {
        r.response.write('ok');
      }
      await r.response.close();
    });
    await expectLater(
      resolver
          .resolveSource(
            'function main(){for(let i=0;i<9;i++)mytv.get("${url(a)}");return {url:"https://fixture.invalid"}}',
          )
          .result,
      throwsA(code('script.resource_limit')),
    );
    expect(count, 8);
    await expectLater(
      resolver
          .resolveSource(
            'function main(){return {url:mytv.get("${url(a, 'big')}")}}',
          )
          .result,
      throwsA(code('script.resource_limit')),
    );
  });
  test('held headers cancellation waits settlement', () async {
    final started = Completer<void>();
    a.listen((r) {
      started.complete();
    });
    final job = resolver.resolveSource(
      'function main(){return {url:mytv.get("${url(a)}")}}',
    );
    final checked = expectLater(job.result, throwsA(code('script.cancelled')));
    await started.future;
    await job.cancel();
    await checked;
  });
  test('held body times out within overall deadline', () async {
    a.listen((r) async {
      r.response.write('partial');
      await r.response.flush();
    });
    final short = YlScriptResolver(
      limits: const YlScriptLimits(timeout: Duration(milliseconds: 200)),
    );
    addTearDown(short.dispose);
    await expectLater(
      short
          .resolveSource('function main(){return {url:mytv.get("${url(a)}")}}')
          .result,
      throwsA(code('script.timeout')),
    );
  });
  test('source credentials are not inherited by host calls', () async {
    final seen = <String?>[];
    a.listen((r) async {
      seen.add(r.headers.value('x-secret'));
      r.response.write(
        r.uri.path == '/source'
            ? 'function main(){return {url:mytv.get("${url(a, 'host')}")}}'
            : 'https://fixture.invalid',
      );
      await r.response.close();
    });
    await resolver
        .resolve(
          YlScriptReference(
            scriptUri: Uri.parse(url(a, 'source')),
            parameters: '',
            headers: {'X-Secret': 'token'},
          ),
        )
        .result;
    expect(seen, ['token', null]);
  });
  test(
    'validated Host is discarded before same and cross origin redirects',
    () async {
      final seen = <String?>[];
      a.listen((r) async {
        seen.add(r.headers.value('host'));
        r.response.statusCode = 302;
        r.response.headers.set('location', url(b));
        await r.response.close();
      });
      b.listen((r) async {
        seen.add(r.headers.value('host'));
        r.response.write('https://fixture.invalid');
        await r.response.close();
      });
      await resolver
          .resolveSource(
            'function main(){return {url:mytv.get("${url(a)}",["Host: 127.0.0.1:${a.port}"])}}',
          )
          .result;
      expect(seen, ['127.0.0.1:${a.port}', '127.0.0.1:${b.port}']);
      await resolver
          .resolveSource(
            'function main(){return {url:mytv.get("${url(a)}",["Host: 127.0.0.1"])}}',
          )
          .result;
      expect(seen.length, 4);

      for (final host in [
        'different.invalid',
        '127.0.0.1:80',
        '127.0.0.1:${b.port}',
        '127.0.0.1:${a.port}/path',
      ]) {
        await expectLater(
          resolver
              .resolveSource(
                'function main(){return {url:mytv.get("${url(a)}",["Host: $host"])}}',
              )
              .result,
          throwsA(code('script.invalid_headers')),
        );
      }
    },
  );

  test(
    'aggregate and redirect-body budgets count bytes before following',
    () async {
      var count = 0;
      a.listen((r) async {
        count++;
        if (r.uri.path == '/redirect') {
          r.response.statusCode = 302;
          r.response.headers.set('location', url(b));
          r.response.add(List.filled(1048577, 65));
        } else {
          r.response.add(List.filled(900000, 65));
        }
        await r.response.close();
      });
      b.listen((r) {
        fail('Oversized redirect must never be followed');
      });
      await expectLater(
        resolver
            .resolveSource(
              'function main(){for(let i=0;i<5;i++)mytv.get("${url(a)}");return {url:"https://fixture.invalid"}}',
            )
            .result,
        throwsA(code('script.resource_limit')),
      );
      expect(count, 5);
      await expectLater(
        resolver
            .resolveSource(
              'function main(){return {url:mytv.get("${url(a, 'redirect')}")}}',
            )
            .result,
        throwsA(code('script.resource_limit')),
      );
      expect(count, 6);
    },
  );
  test('download size and shared download deadline are enforced', () async {
    a.listen((r) async {
      if (r.uri.path == '/big') {
        r.response.add(List.filled(524289, 65));
        await r.response.close();
      } else {
        r.response.write('partial');
        await r.response.flush();
      }
    });
    await expectLater(
      resolver
          .resolve(
            YlScriptReference(
              scriptUri: Uri.parse(url(a, 'big')),
              parameters: '',
            ),
          )
          .result,
      throwsA(code('script.resource_limit')),
    );
    final short = YlScriptResolver(
      limits: const YlScriptLimits(timeout: Duration(milliseconds: 150)),
    );
    addTearDown(short.dispose);
    await expectLater(
      short
          .resolve(
            YlScriptReference(
              scriptUri: Uri.parse(url(a, 'held')),
              parameters: '',
            ),
          )
          .result,
      throwsA(code('script.timeout')),
    );
  });
  test('host advertises supported gzip and cancels held response body', () async {
    final started = Completer<void>();
    a.listen((r) async {
      expect(r.headers.value('accept-encoding'), 'gzip');
      r.response.write('held');
      await r.response.flush();
      started.complete();
    });
    final job = resolver.resolveSource(
      'function main(){return {url:mytv.get("${url(a)}",["Accept-Encoding: br, zstd"])}}',
    );
    final check = expectLater(job.result, throwsA(code('script.cancelled')));
    await started.future;
    await job.cancel();
    await check;
    expect(
      (await resolver
              .resolveSource(
                'function main(){return {url:"https://fixture.invalid"}}',
              )
              .result)
          .uri
          .host,
      'fixture.invalid',
    );
  });
}
