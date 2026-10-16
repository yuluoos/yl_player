import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:yl_player_source_resolver/src/script_http.dart';
import 'package:yl_player_source_resolver/yl_player_source_resolver.dart';

const frozenScripts = <String, (String, String, String)>{
  'JS-01': (
    'bjtime.js',
    'id=bjws4k',
    '5a217f208bce349c3f4bde904f67dd10f071a329603966a919f24b523a48a034',
  ),
  'JS-02': (
    'cctvnews.js',
    'id=cctv1',
    '5297480cc156df777a9578dd303bb4eb1e80235d0316038ee5ba3f0c6febe3ea',
  ),
  'JS-03': (
    'guangzhou.js',
    'id=zhonghe',
    'e8bc63ce38d2675dfc1ff1d2139e1baf51242ddba95e60bcb515c6dbcb3918d5',
  ),
  'JS-04': (
    'gz.js',
    'id=ch01',
    'd9c0e65fadf8c72b837c8dce548b59b36648dd1660353796d4dade60fa1c6b9f',
  ),
  'JS-05': (
    'hainan.js',
    'id=hnws',
    'e89a36134251782f23da093ae1c1039ec1499e0b817b453e97a97f3aef266a1f',
  ),
  'JS-06': (
    'sh.js',
    'id=dfws',
    'df3915e4162c3a71d9c0cd8d5cf7579def4c2450d1adc629380a17bd601dc481',
  ),
  'JS-07': (
    'sz.js',
    'id=szws',
    '701f53b46ffdff66cfc8ae0704f71d223d034b7c2b2fba46f84a7cbc18057848',
  ),
  'JS-08': (
    'xj.js',
    'id=xjws',
    'aa33edda8604250549029e18741b935a506456e6a4dd1544775cd316b5be068d',
  ),
  'JS-09': (
    'zj.js',
    'id=01',
    'c004d274717c482254b2f70ac8304a124fc7acc17e2ac06fb6c3b31f2c627acc',
  ),
};

const fixtureUrl = 'https://fixture.invalid/controlled.m3u8';

Uint8List fixtureEncrypt(List<int> plain, List<int> key, List<int> iv) {
  final cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))..init(
        true,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV(
            KeyParameter(Uint8List.fromList(key)),
            Uint8List.fromList(iv),
          ),
          null,
        ),
      );
  return cipher.process(Uint8List.fromList(plain));
}

ScriptHttpReply fixtureResponse(String id, Map<String, String> headers) {
  Object body;
  switch (id) {
    case 'JS-01':
      body = {
        'data': {
          'video_stream': [
            {'stream_url': fixtureUrl},
          ],
        },
      };
    case 'JS-02':
      const dk = 'fixture-key-material-32-chars-abc';
      final time = headers['x-emas-gw-t'];
      if (time == null || !RegExp(r'^\d{10}$').hasMatch(time)) {
        throw StateError('Fixture timestamp missing');
      }
      final key = dk.substring(0, 8) + time.substring(time.length - 8);
      final iv = dk.substring(dk.length - 8) + time.substring(0, 8);
      final auth = base64Encode(
        fixtureEncrypt(
          utf8.encode(fixtureUrl),
          utf8.encode(key),
          utf8.encode(iv),
        ),
      );
      final inner = {
        'data': {
          'dk': dk,
          'live_room': {
            'liveCameraList': [
              {
                'pullUrlList': [
                  {
                    'authResultUrl': [
                      {'authUrl': auth},
                    ],
                  },
                ],
              },
            ],
          },
        },
      };
      body = {'response': base64Encode(utf8.encode(jsonEncode(inner)))};
    case 'JS-03':
      body = {
        'data': [
          {'httpUrl': fixtureUrl},
        ],
      };
    case 'JS-04':
      body = {'stream_url': fixtureUrl};
    case 'JS-05':
      body = {
        'resultSet': [
          {'url': fixtureUrl},
        ],
      };
    case 'JS-06':
      body = {
        'dt': [
          {'id': 2030, 'channelUrl': fixtureUrl},
        ],
      };
    case 'JS-07':
      body = {
        'key': 'fixture-key',
        'ip': '192.0.2.1',
        'sign': '{IP}|{KEY}|{PATH}|{T}',
      };
    case 'JS-08':
      body = {
        'data': [
          {'Id': 1, 'PlayStreamUrl': fixtureUrl},
        ],
      };
    default:
      throw StateError('Unexpected fixture request');
  }
  return ScriptHttpReply(200, utf8.encode(jsonEncode(body)));
}

// JS-07 derives its media path from the ambient date. Keep the original bytes
// and historical path digest, but make its controlled environment reproducible.
// This is fixture-only: production resolution continues to use the real clock.
String controlledScriptSource(String id, String source) => id != 'JS-07'
    ? source
    : r'''(() => {
  const NativeDate = Date;
  const epoch = NativeDate.UTC(2026, 8, 22, 12);
  function ControlledDate(...args) {
    if (!new.target) return new NativeDate(epoch).toString();
    return Reflect.construct(NativeDate, args.length ? args : [epoch], new.target);
  }
  Object.setPrototypeOf(ControlledDate, NativeDate);
  ControlledDate.prototype = NativeDate.prototype;
  ControlledDate.now = () => epoch;
  globalThis.Date = ControlledDate;
})();
''' +
          source;

/// Both host tests and generated device tests use this exact fixture suite.
/// Sources must contain original UTF-8 bytes; no original script is tracked.
void registerControlledContracts(Map<String, String> base64Sources) {
  test('fixture AES CBC PKCS7 independent known answer', () {
    List<int> hex(String value) => [
      for (var i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ];
    final encrypted = fixtureEncrypt(
      hex('6bc1bee22e409f96e93d7e117393172a'),
      hex('2b7e151628aed2a6abf7158809cf4f3c'),
      hex('000102030405060708090a0b0c0d0e0f'),
    );
    expect(
      encrypted.take(16).toList(),
      hex('7649abac8119b246cee98e9b12e9197d'),
    );
    expect(encrypted.length, 32);
  });
  for (final entry in frozenScripts.entries) {
    test(
      '${entry.key} controlled failures malformed input timeout cancellation',
      () async {
        final source = controlledScriptSource(
          entry.key,
          utf8.decode(base64Decode(base64Sources[entry.key]!)),
        );
        final resolver = YlScriptResolver();
        addTearDown(resolver.dispose);
        await withScriptHttpFixture(
          (uri, method, headers, body) async =>
              ScriptHttpReply(200, utf8.encode('{}')),
          () async {
            try {
              await resolver
                  .resolveSource(source, parameters: entry.value.$2)
                  .result;
              expect(entry.key == 'JS-09', isTrue);
            } on YlScriptException catch (error) {
              expect(entry.key != 'JS-09', isTrue);
              expect(error.toString().contains('http'), isFalse);
            }
          },
        );
        await withScriptHttpFixture(
          (uri, method, headers, body) async =>
              fixtureResponse(entry.key, headers),
          () async {
            try {
              final result = await resolver
                  .resolveSource(source, parameters: 'id=%ZZ')
                  .result;
              expect(result.uri.host.isNotEmpty, isTrue);
            } on YlScriptException catch (error) {
              expect(error.code.startsWith('script.'), isTrue);
            }
          },
        );
        if (entry.key != 'JS-09') {
          var failedHostCalls = 0;
          await expectLater(
            withScriptHttpFixture(
              (uri, method, headers, body) async {
                failedHostCalls++;
                throw const SocketException('Controlled host unavailable');
              },
              () => resolver.resolveSource(source, parameters: entry.value.$2),
            ).result,
            throwsA(
              isA<YlScriptException>()
                  .having((e) => e.code, 'code', 'script.execution')
                  .having((e) => e.phase, 'phase', 'host'),
            ),
          );
          expect(failedHostCalls, 1);
        }
        final cancelled = withScriptHttpFixture(
          (uri, method, headers, body) async =>
              fixtureResponse(entry.key, headers),
          () => resolver.resolveSource(source, parameters: entry.value.$2),
        );
        final cancelCheck = expectLater(
          cancelled.result,
          throwsA(
            isA<YlScriptException>().having(
              (e) => e.code,
              'code',
              'script.cancelled',
            ),
          ),
        );
        await cancelled.cancel();
        await cancelCheck;
        final timed = YlScriptResolver(
          limits: const YlScriptLimits(timeout: Duration(milliseconds: 1)),
        );
        addTearDown(timed.dispose);
        await expectLater(
          withScriptHttpFixture(
            (uri, method, headers, body) async =>
                fixtureResponse(entry.key, headers),
            () => timed.resolveSource(source, parameters: entry.value.$2),
          ).result,
          throwsA(
            isA<YlScriptException>().having(
              (e) => e.code,
              'code',
              'script.timeout',
            ),
          ),
        );
      },
    );
    test(
      '${entry.key} frozen bytes native main controlled success and refresh',
      () async {
        final raw = base64Decode(base64Sources[entry.key]!);
        // Assert only digests; never expose source bytes or returned real hosts.
        expect(sha256.convert(raw).toString(), entry.value.$3);
        final source = controlledScriptSource(entry.key, utf8.decode(raw));
        var calls = 0;
        final resolver = YlScriptResolver();
        addTearDown(resolver.dispose);
        await withScriptHttpFixture(
          (uri, method, headers, body) async {
            calls++;
            expect(uri.scheme == 'http' || uri.scheme == 'https', isTrue);
            expect(uri.userInfo.isEmpty, isTrue);
            expect(method, entry.key == 'JS-06' ? 'POST' : 'GET');
            if (entry.key == 'JS-06') expect(utf8.decode(body), '{}');
            return fixtureResponse(entry.key, headers);
          },
          () async {
            for (var run = 0; run < 2; run++) {
              final result = await resolver
                  .resolveSource(source, parameters: entry.value.$2)
                  .result;
              expect(result.expiresAt, isNull);
              if (entry.key == 'JS-07' || entry.key == 'JS-09') {
                final uri = result.uri;
                expect(
                  sha256.convert(utf8.encode(uri.path)).toString(),
                  entry.key == 'JS-07'
                      ? '10502e8ad9a86c4146cad208b0e808bf1b0eeb14f66f40933d5c442882e828fd'
                      : '399c384d62ee3db752c8fa5b107bff64c71db56fee1786b1d094499c400aef7f',
                );
                final query = uri.queryParameters;
                if (entry.key == 'JS-07') {
                  expect(query.keys.toSet(), {'sign', 't'});
                  expect(
                    RegExp(r'^[0-9a-f]{32}$').hasMatch(query['sign'] ?? ''),
                    isTrue,
                  );
                  expect(
                    RegExp(r'^[0-9a-f]{8}$').hasMatch(query['t'] ?? ''),
                    isTrue,
                  );
                } else {
                  expect(query.keys.toSet(), {'auth_key'});
                  expect(
                    RegExp(
                      r'^\d{10}-[0-9a-f]{32}-0-[0-9a-f]{32}$',
                    ).hasMatch(query['auth_key'] ?? ''),
                    isTrue,
                  );
                }
              } else {
                expect(result.uri.toString() == fixtureUrl, isTrue);
              }
              expect(
                result.headers.isNotEmpty,
                entry.key == 'JS-05' || entry.key == 'JS-07',
              );
            }
          },
        );
        expect(calls, entry.key == 'JS-09' ? 0 : 2);
      },
    );
  }
}
