import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../models.dart';

/// Network limits also apply to description, SCPD and SOAP responses.
class DlnaTransport {
  DlnaTransport({this.timeout = const Duration(seconds: 5)});
  final Duration timeout;
  final _clients = <HttpClient>{};
  bool _closed = false;
  static const maxBytes = 1024 * 1024;

  Future<XmlDocument> get(Uri uri) => _request(uri);

  Future<XmlDocument> soap(
    Uri uri,
    String service,
    String action,
    Map<String, String> arguments,
  ) {
    final body =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="${escapeXml(service)}">'
        '${arguments.entries.map((e) => '<${e.key}>${escapeXml(e.value)}</${e.key}>').join()}'
        '</u:$action></s:Body></s:Envelope>';
    return _request(
      uri,
      body: body,
      soapAction: '"$service#$action"',
      expectedService: service,
      expectedAction: action,
    );
  }

  Future<XmlDocument> _request(
    Uri uri, {
    String? body,
    String? soapAction,
    String? expectedService,
    String? expectedAction,
  }) async {
    validateHttpUri(uri);
    if (_closed) throw const YlCastException('cast.disposed');
    final client = HttpClient()..connectionTimeout = timeout;
    _clients.add(client);
    Future<XmlDocument> perform() async {
      final request = await client.openUrl(body == null ? 'GET' : 'POST', uri);
      request.followRedirects = false;
      if (body != null) {
        final bytes = utf8.encode(body);
        request.headers.set('Content-Type', 'text/xml; charset="utf-8"');
        request.headers.set('SOAPACTION', soapAction!);
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close();
      if (response.isRedirect) {
        throw const YlCastException('cast.redirect_rejected');
      }
      if (response.contentLength > maxBytes) {
        throw const YlCastException('cast.response_too_large');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const YlCastException('cast.response_too_large');
        }
        bytes.addAll(chunk);
      }
      final document = parseXml(utf8.decode(bytes));
      if (expectedAction != null) {
        const soapNamespace = 'http://schemas.xmlsoap.org/soap/envelope/';
        final envelope = document.rootElement;
        final bodies = envelope.childElements
            .where(
              (e) =>
                  e.name.local == 'Body' &&
                  e.name.namespaceUri == soapNamespace,
            )
            .toList();
        if (envelope.name.local != 'Envelope' ||
            envelope.name.namespaceUri != soapNamespace ||
            bodies.length != 1) {
          throw const YlCastException('cast.invalid_soap');
        }
        final payloads = bodies.single.childElements.toList();
        if (payloads.length != 1) {
          throw const YlCastException('cast.invalid_soap');
        }
        final payload = payloads.single;
        if (payload.name.local == 'Fault' &&
            payload.name.namespaceUri == soapNamespace) {
          final code = textOf(payload, 'errorCode');
          throw YlCastException(
            RegExp(r'^\d{3}$').hasMatch(code)
                ? 'cast.upnp_$code'
                : 'cast.soap_fault',
          );
        }
        if (payload.name.local != '${expectedAction}Response' ||
            payload.name.namespaceUri != expectedService) {
          throw const YlCastException('cast.invalid_soap');
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const YlCastException('cast.http_failed');
      }
      return document;
    }

    try {
      return await perform().timeout(timeout);
    } on YlCastException {
      rethrow;
    } on TimeoutException {
      throw const YlCastException('cast.timeout');
    } on FormatException {
      throw const YlCastException('cast.invalid_xml');
    } on Object {
      throw const YlCastException('cast.network_failed');
    } finally {
      client.close(force: true);
      _clients.remove(client);
    }
  }

  void dispose() {
    _closed = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
  }
}

void validateHttpUri(Uri uri) {
  if (!['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw const YlCastException('cast.invalid_url');
  }
}

XmlDocument parseXml(String source) {
  if (RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(source)) {
    throw const YlCastException('cast.unsafe_xml');
  }
  try {
    var depth = 0;
    for (final event in parseEvents(source, validateNesting: true)) {
      if (event is XmlStartElementEvent) {
        if (depth + 1 > 32) throw const YlCastException('cast.xml_too_deep');
        if (!event.isSelfClosing) depth++;
      } else if (event is XmlEndElementEvent) {
        depth--;
      }
    }
    return XmlDocument.parse(source);
  } on YlCastException {
    rethrow;
  } on Object {
    throw const YlCastException('cast.invalid_xml');
  }
}

Iterable<XmlElement> elements(XmlNode node, String name) =>
    node.descendants.whereType<XmlElement>().where((e) => e.name.local == name);
String textOf(XmlNode node, String name) =>
    elements(node, name).firstOrNull?.innerText.trim() ?? '';
String escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
