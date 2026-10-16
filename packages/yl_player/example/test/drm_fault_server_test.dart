import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import '../integration_test/support/drm_fault_server.dart';

Matcher code(String expected) => throwsA(
  isA<YlPlayerException>().having((e) => e.failure.code, 'code', expected),
);

void main() {
  test('fault selector rejects missing and arbitrary values safely', () {
    for (final value in ['', 'SECRET', 'expiry']) {
      expect(() => DrmFault.parse(value), throwsFormatException);
    }
    expect(DrmFault.parse('denied'), DrmFault.denied);
    expect(DrmFault.parse('timeout'), DrmFault.timeout);
    expect(DrmFault.parse('cancel'), DrmFault.cancel);
  });

  for (final fault in DrmFault.values) {
    test(
      '${fault.name} real POST uses bounded loopback and safe receipt',
      () async {
        final server = await DrmFaultServer.start(fault);
        addTearDown(server.close);
        final client = YlDrmLicenseClient();
        addTearDown(client.close);
        final token = YlDrmCancellationToken();
        final endpoint = server.endpoint(
          timeout: fault == DrmFault.timeout
              ? const Duration(milliseconds: 200)
              : const Duration(seconds: 2),
        );
        expect(endpoint.request.headers, isEmpty);
        expect(endpoint.request.credentials, isEmpty);
        expect(endpoint.maxRetries, 0);
        expect(endpoint.allowSameOriginRedirects, isFalse);
        final result = expectLater(
          client.send(
            endpoint,
            YlDrmBytes(utf8.encode('PRIVATE_CHALLENGE')),
            cancellation: token,
          ),
          code(fault.expectedCode),
        );
        await server.firstChallenge.timeout(const Duration(seconds: 2));
        if (fault == DrmFault.cancel) token.cancel();
        await result;
        expect(server.requestCount, 1);
        expect(server.challengeCount, 1);
        expect(jsonEncode(server.report), isNot(contains('PRIVATE_CHALLENGE')));
        expect(jsonEncode(server.report), isNot(contains('127.0.0.1')));
        await server.close();
        await server.close();
      },
    );
  }

  test(
    'invalid or empty requests cannot satisfy challenge observation',
    () async {
      final server = await DrmFaultServer.start(DrmFault.denied);
      addTearDown(server.close);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      for (final method in ['GET', 'POST']) {
        final request = await client.openUrl(method, server.endpoint().uri);
        request.headers.contentType = ContentType.binary;
        final response = await request.close();
        expect(response.statusCode, 400);
        await response.drain<void>();
      }
      expect(server.requestCount, 2);
      expect(server.challengeCount, 0);
      await expectLater(
        server.firstChallenge.timeout(const Duration(milliseconds: 30)),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  test('oversized challenge rejected without retaining bytes', () async {
    final server = await DrmFaultServer.start(DrmFault.denied);
    addTearDown(server.close);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(server.endpoint().uri);
    request.headers.contentType = ContentType.binary;
    request.add(List.filled(1024 * 1024 + 1, 1));
    try {
      final response = await request.close();
      expect(response.statusCode, 413);
      await response.drain<void>();
    } on HttpException {
      // Cancelling a chunked request at the byte limit may abort its socket
      // before the 413 headers flush. Both outcomes reject the oversized body.
    }
    expect(server.requestCount, 1);
    expect(server.challengeCount, 0);
  });
}
