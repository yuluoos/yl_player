import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_cast/src/dlna/transport.dart';
import 'package:yl_player_cast/src/models.dart';

void main() {
  late HttpServer server;
  late DlnaTransport transport;
  late Uri uri;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    uri = Uri.parse('http://127.0.0.1:${server.port}/device');
    transport = DlnaTransport(timeout: const Duration(seconds: 2));
  });
  tearDown(() async {
    transport.dispose();
    await server.close(force: true);
  });
  Matcher code(String expected) =>
      throwsA(isA<YlCastException>().having((e) => e.code, 'code', expected));

  test('SOAP uses UTF-8 byte Content-Length without chunked encoding', () async {
    late List<int> received;
    int? length;
    String? transferEncoding;
    server.listen((request) async {
      length = request.contentLength;
      transferEncoding = request.headers.value('transfer-encoding');
      received = await request.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      request.response.write(
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
        '<u:SetAVTransportURIResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"/>'
        '</s:Body></s:Envelope>',
      );
      await request.response.close();
    });
    await transport.soap(
      uri,
      'urn:schemas-upnp-org:service:AVTransport:1',
      'SetAVTransportURI',
      {'CurrentURIMetaData': '电影 🎬 & café'},
    );
    expect(utf8.decode(received), contains('电影 🎬 &amp; café'));
    expect(length, received.length);
    expect(transferEncoding, isNull);
  });

  test('streamed oversized response is aborted before XML parsing', () async {
    server.listen((request) async {
      request.response.add(List.filled(1024 * 1024 + 1, 32));
      await request.response.close();
    });
    await expectLater(transport.get(uri), code('cast.response_too_large'));
  });
  test(
    'timeout includes stalled body, not only connection establishment',
    () async {
      transport.dispose();
      transport = DlnaTransport(timeout: const Duration(milliseconds: 100));
      server.listen((request) async {
        request.response.write('<root>');
        await request.response.flush();
      });
      await expectLater(transport.get(uri), code('cast.timeout'));
    },
  );
  test(
    'credentials and non HTTP control addresses fail before network',
    () async {
      var requests = 0;
      server.listen((request) {
        requests++;
        request.response.close();
      });
      await expectLater(
        transport.get(uri.replace(userInfo: 'user:secret')),
        code('cast.invalid_url'),
      );
      await expectLater(
        transport.get(Uri.parse('file:///private/secret')),
        code('cast.invalid_url'),
      );
      expect(requests, 0);
    },
  );
  test('dispose aborts in-flight request and blocks future requests', () async {
    final received = Completer<void>();
    server.listen((request) {
      received.complete();
    });
    final pending = transport.get(uri);
    final assertion = expectLater(pending, throwsA(isA<YlCastException>()));
    await received.future;
    transport.dispose();
    await assertion;
    await expectLater(transport.get(uri), code('cast.disposed'));
  });
}
