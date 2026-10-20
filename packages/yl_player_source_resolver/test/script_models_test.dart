import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'package:yl_player_source_resolver/src/script_models.dart';

void main() {
  YlResolvedSource result(
    String url, {
    Map<String, String>? headers,
    String? expiry,
  }) => normalizeScriptResult(
    jsonEncode({'url': url, 'headers': headers, 'expiresAt': ?expiry}),
  );
  Matcher failure(String code) =>
      isA<YlScriptException>().having((e) => e.code, 'code', code);

  for (final scheme in ['rtmp', 'rtmps']) {
    test('header-free $scheme result converts to a validated live source', () {
      for (final authority in ['media.test', 'media.test:8443']) {
        final url = '$scheme://$authority/app/stream?key=a%2Fb+q';
        final resolved = result(url);
        final source = resolved.toNetworkSource();
        expect(identical(source.uri, resolved.uri), isTrue);
        expect(source.uri.toString(), url);
        expect(source.intent, YlStreamIntent.live);
        expect(source.format, YlMediaFormat.automatic);
        expect(source.request.headers, isEmpty);
        expect(source.request.credentials, isEmpty);
        validateYlSource(source);
      }
    });
    test('$scheme conversion retains opaque app playpath and query bytes', () {
      for (final value in [
        '$scheme://media.test/app%FF/stream',
        '$scheme://media.test/app/stream%FF',
        '$scheme://media.test/app/stream?key=%FE',
        '$scheme://media.test/app%85/stream%C3%A9?key=%FE+%FF',
      ]) {
        final resolved = result(value);
        final source = resolved.toNetworkSource();
        expect(identical(source.uri, resolved.uri), isTrue);
        expect(source.uri.toString(), value);
      }
    });
    test('$scheme conversion rejects all nonempty HTTP headers', () {
      for (final headers in [
        {'Accept': 'video/*'},
        {'Authorization': 'secret'},
      ]) {
        expect(
          () => result(
            '$scheme://media.test/app/stream',
            headers: headers,
          ).toNetworkSource(),
          throwsA(failure('script.invalid_headers')),
        );
      }
    });
    test('$scheme conversion uses core URI validation with safe errors', () {
      for (final url in [
        '$scheme://media.test/app',
        '$scheme://media.test/app/stream%00',
        '$scheme://media.test/app%FF/stream%00',
        '$scheme://media.test/app/stream%FF?key=%7F',
        '$scheme://media.test/app/stream?key=%FF%C2%85',
        '$scheme://media.test:65536/app/stream',
        '$scheme://user:secret@media.test/app/stream',
        '$scheme://media.test/app/stream#fragment',
        '$scheme://media.test/app/${'x' * 8192}',
      ]) {
        expect(
          () => result(url).toNetworkSource(),
          throwsA(failure('script.invalid_url')),
        );
      }
    });
    test('$scheme expiry is checked during resolution', () {
      expect(
        () => result(
          '$scheme://media.test/app/stream',
          expiry: '2000-01-01T00:00:00Z',
        ),
        throwsA(failure('script.expired')),
      );
    });
    test('$scheme conversion rechecks expiry after resolution', () async {
      final resolved = result(
        '$scheme://media.test/app/stream',
        expiry: DateTime.now()
            .toUtc()
            .add(const Duration(milliseconds: 100))
            .toIso8601String(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(resolved.toNetworkSource, throwsA(failure('script.expired')));
    });
  }
  test('HTTP conversion keeps credentials', () {
    final source = result(
      'https://media.test/a',
      headers: {'Authorization': 'secret'},
      expiry: '2099-01-01T00:00:00Z',
    ).toNetworkSource();
    expect(source.request.credentials, {'authorization': 'secret'});
  });
  test('reference parser preserves raw query spelling and plus', () {
    final reference = YlScriptReference.parse(
      'javascript://https://fixture.invalid/a.js?id=a%2fb+z&x=a=b',
    );
    expect(reference.scriptUri.toString(), 'https://fixture.invalid/a.js');
    expect(reference.parameters, 'id=a%2fb+z&x=a=b');
    expect(reference.toString(), isNot(contains('fixture.invalid')));
  });
  test('reference rejects unsafe transport and parameters', () {
    for (final url in [
      'file:///a',
      'https://user:SECRET@fixture.invalid/a',
      'https://fixture.invalid/a#fragment',
    ]) {
      expect(
        () => YlScriptReference(scriptUri: Uri.parse(url), parameters: ''),
        throwsA(isA<YlScriptException>()),
      );
    }
    expect(
      () => YlScriptReference(
        scriptUri: Uri.parse('https://fixture.invalid'),
        parameters: 'x' * 8193,
      ),
      throwsA(isA<YlScriptException>()),
    );
  });
}
