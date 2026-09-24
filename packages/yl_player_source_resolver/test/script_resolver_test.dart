import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'package:yl_player_source_resolver/yl_player_source_resolver.dart';

Matcher code(String value) =>
    isA<YlScriptException>().having((e) => e.code, 'code', value);
void main() {
  late YlScriptResolver resolver;
  setUp(() {
    resolver = YlScriptResolver();
  });
  tearDown(() => resolver.dispose());
  test(
    'real main returns raw parameters and live credential conversion',
    () async {
      final result = await resolver
          .resolveSource(
            'function main(p){return JSON.stringify({url:"https://fixture.invalid/"+p,headers:"Referer: secret:one\\nreferer: secret:one"})}',
            parameters: 'x%2fb+q',
          )
          .result;
      expect(result.uri.toString(), 'https://fixture.invalid/x%2Fb+q');
      expect(result.headers, {'referer': 'secret:one'});
      expect(result.expiresAt, isNull);
      expect(result.toString(), isNot(contains('secret')));
      expect(result.toNetworkSource().intent, YlStreamIntent.live);
      expect(result.toNetworkSource().request.credentials, result.headers);
    },
  );
  test('error takes precedence over URL and never exposes payload', () async {
    try {
      await resolver
          .resolveSource(
            'function main(){return {url:"https://fixture.invalid",error:"SECRET"}}',
          )
          .result;
      fail('expected error');
    } on YlScriptException catch (e) {
      expect(e.code, 'script.reported_error');
      expect(e.toString(), isNot(contains('SECRET')));
    }
  });
  test('headers reject CRLF injection and conflicting duplicates', () async {
    for (final headers in [
      {'X': 'a\r\nSecret: bad'},
      ['X: a', 'x: b'],
      ['Host: bad'],
    ]) {
      await expectLater(
        resolver
            .resolveSource(
              'function main(){return {url:"https://fixture.invalid",headers:${jsonEncode(headers)}}}',
            )
            .result,
        throwsA(code('script.invalid_headers')),
      );
    }
  });
  test('expiry is explicit UTC and expired source rejected', () async {
    for (final expiry in [
      '2000-01-01T00:00:00Z',
      'not-date',
      '2099-01-01',
      '2099-13-01T00:00:00Z',
    ]) {
      await expectLater(
        resolver
            .resolveSource(
              'function main(){return {url:"https://fixture.invalid",expiresAt:"$expiry"}}',
            )
            .result,
        throwsA(
          code(
            expiry.startsWith('2000')
                ? 'script.expired'
                : 'script.invalid_result',
          ),
        ),
      );
    }
  });
  test('RTMP live conversion succeeds; file output rejected', () async {
    final result = await resolver
        .resolveSource(
          'function main(){return {url:"rtmp://fixture.invalid/live/stream"}}',
        )
        .result;
    expect(result.uri.scheme, 'rtmp');
    expect(result.toNetworkSource().intent, YlStreamIntent.live);
    expect(result.toNetworkSource().request.credentials, isEmpty);
    await expectLater(
      resolver
          .resolveSource('function main(){return {url:"file:///secret"}}')
          .result,
      throwsA(code('script.invalid_url')),
    );
  });
  test(
    'unsupported host API and thrown secrets use safe fixed failures',
    () async {
      await expectLater(
        resolver
            .resolveSource(
              'function main(){try{mytv.unknown()}catch(e){}return {url:"https://fixture.invalid"}}',
            )
            .result,
        throwsA(code('script.host_api_unsupported')),
      );
      await expectLater(
        resolver
            .resolveSource('function main(){throw new Error("SECRET")}')
            .result,
        throwsA(code('script.execution')),
      );
    },
  );
  test(
    'parseItems contract handles first equals decoding and null prototype',
    () async {
      final result = await resolver
          .resolveSource(
            'function main(p){const q=parseItems(p);return {url:"https://fixture.invalid/"+encodeURIComponent(q.x+"|"+q.y+"|"+Object.getPrototypeOf(q))}}',
            parameters: 'x=first&x=a%3Db+c&y&__proto__=safe',
          )
          .result;
      expect(Uri.decodeComponent(result.uri.path.substring(1)), 'a=b c||null');
    },
  );
  test(
    'cancel and dispose await actual cleanup; fresh resolution works',
    () async {
      final job = resolver.resolveSource('function main(){while(true){}}');
      final assertion = expectLater(
        job.result,
        throwsA(code('script.cancelled')),
      );
      await job.cancel();
      await assertion;
      await resolver.dispose();
      await expectLater(
        resolver.resolveSource('').result,
        throwsA(code('script.disposed')),
      );
      final fresh = YlScriptResolver();
      addTearDown(fresh.dispose);
      expect(
        (await fresh
                .resolveSource(
                  'function main(){return {url:"https://fixture.invalid"}}',
                )
                .result)
            .uri
            .host,
        'fixture.invalid',
      );
    },
  );
  test(
    'deadline stops actual native loop and oversized inputs rejected',
    () async {
      final bounded = YlScriptResolver(
        limits: const YlScriptLimits(timeout: Duration(milliseconds: 150)),
      );
      addTearDown(bounded.dispose);
      await expectLater(
        bounded.resolveSource('while(true){}').result,
        throwsA(code('script.timeout')),
      );
      await expectLater(
        bounded.resolveSource('x' * 524289).result,
        throwsA(code('script.resource_limit')),
      );
    },
  );
  test(
    'four owned native jobs admission disposal and late result isolation',
    () async {
      final jobs = [
        for (var i = 0; i < 4; i++)
          resolver.resolveSource('function main(){while(true){}}'),
      ];
      final checked = [
        for (final job in jobs)
          expectLater(job.result, throwsA(code('script.cancelled'))),
      ];
      await expectLater(
        resolver
            .resolveSource(
              'function main(){return {url:"https://fixture.invalid"}}',
            )
            .result,
        throwsA(code('script.resource_limit')),
      );
      await resolver.dispose();
      await Future.wait(checked);
      final fresh = YlScriptResolver();
      addTearDown(fresh.dispose);
      final first = fresh.resolveSource(
        'function main(){return {url:"https://fixture.invalid/old"}}',
      );
      final cancelled = expectLater(
        first.result,
        throwsA(code('script.cancelled')),
      );
      await first.cancel();
      await cancelled;
      expect(
        (await fresh
                .resolveSource(
                  'function main(){return {url:"https://fixture.invalid/new"}}',
                )
                .result)
            .uri
            .path,
        '/new',
      );
    },
  );
  test('heap output limits and malformed parseItems fail safely', () async {
    for (final entry in <(String, String)>[
      (
        'function main(){const a=[];while(true)a.push(new Array(10000).fill(1))}',
        'script.resource_limit',
      ),
      (
        'function main(){return {url:"https://fixture.invalid/"+"a".repeat(70000)}}',
        'script.resource_limit',
      ),
      (
        'function main(){return {url:parseItems("x=%ZZ").x}}',
        'script.execution',
      ),
    ]) {
      await expectLater(
        resolver.resolveSource(entry.$1).result,
        throwsA(code(entry.$2)),
      );
    }
  });
  test('safe errors correlate each resolution with its fixed phase', () async {
    final ids = <String>{};
    for (final source in [
      'function main(){throw Error("SECRET")}',
      'function main(){return {error:"SECRET"}}',
    ]) {
      final job = resolver.resolveSource(source);
      try {
        await job.result;
        fail('Expected failure');
      } on YlScriptException catch (error) {
        expect(error.diagnosticId, isNotEmpty);
        expect(error.diagnosticId, job.diagnosticId);
        ids.add(error.diagnosticId);
        expect(error.phase, source.contains('throw') ? 'evaluation' : 'result');
        expect(error.toString(), isNot(contains('SECRET')));
      }
    }
    expect(ids.length, 2);
  });
}
