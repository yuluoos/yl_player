import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'script_models.dart';

/// Package-internal fixture seam. Not exported by the public library. Tests
/// intercept every exchange, including source downloads, without real network.
typedef ScriptHttpFixture =
    Future<ScriptHttpReply> Function(
      Uri uri,
      String method,
      Map<String, String> headers,
      List<int> body,
    );
final Object _fixtureKey = Object();
T withScriptHttpFixture<T>(ScriptHttpFixture fixture, T Function() body) =>
    runZoned(body, zoneValues: {_fixtureKey: fixture});

final class ScriptHttpReply {
  ScriptHttpReply(this.code, this.bytes, {this.location});
  final int code;
  final List<int> bytes;
  final String? location;
  @override
  String toString() => 'ScriptHttpReply(code: $code, <redacted>)';
}

/// One transport owner for a single resolution. The owner enforces the overall
/// deadline and invokes abort before awaiting outstanding work and VM cleanup.
final class ScriptHttp {
  ScriptHttp() : _fixture = Zone.current[_fixtureKey] as ScriptHttpFixture?;
  final ScriptHttpFixture? _fixture;
  final HttpClient _client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..autoUncompress = true;
  int _calls = 0;
  int _totalBytes = 0;
  bool _closed = false;
  final Set<HttpClientRequest> _requests = {};

  void abort() {
    if (_closed) return;
    _closed = true;
    for (final request in _requests) {
      request.abort();
    }
    _client.close(force: true);
  }

  Future<String> download(YlScriptReference reference) async {
    final reply = await _send(
      reference.scriptUri,
      'GET',
      normalizeScriptHeaders(reference.headers, host: true, bodyLength: 0),
      const [],
      source: true,
    );
    if (reply.code < 200 || reply.code >= 300) {
      throw scriptFailure(reply.code == 403 ? 'http_forbidden' : 'http_status');
    }
    try {
      return utf8.decode(reply.bytes);
    } on FormatException {
      throw scriptFailure('syntax');
    }
  }

  Future<Object> host(String requestJson) async {
    if (++_calls > 8) throw scriptFailure('resource_limit');
    checkScriptBytes(requestJson, 65536);
    final value = jsonDecode(requestJson) as Map<String, dynamic>;
    final method = value['method'];
    final args = value['args'];
    if (args is! List || args.isEmpty || args.first is! String) {
      throw scriptFailure('invalid_url');
    }
    final uri = Uri.tryParse(args.first as String);
    if (uri == null) throw scriptFailure('invalid_url');
    var verb = 'GET';
    Object? headers;
    Object? body;
    switch (method) {
      case 'get':
        if (args.length > 2) throw scriptFailure('invalid_result');
        headers = args.length > 1 ? args[1] : null;
      case 'fetch':
        if (args.length != 1) throw scriptFailure('invalid_result');
      case 'post':
        if (args.length != 3) throw scriptFailure('invalid_result');
        verb = 'POST';
        headers = args[1];
        body = args[2];
      case 'request':
        if (args.length < 3 || args.length > 4 || args[1] is! String) {
          throw scriptFailure('invalid_result');
        }
        verb = (args[1] as String).toUpperCase();
        headers = args[2];
        body = args.length > 3 ? args[3] : null;
      default:
        throw scriptFailure('host_api_unsupported');
    }
    if (!const [
          'GET',
          'POST',
          'PUT',
          'PATCH',
          'DELETE',
          'HEAD',
          'OPTIONS',
        ].contains(verb) ||
        (body != null && body is! String)) {
      throw scriptFailure('invalid_result');
    }
    final bytes = utf8.encode(body as String? ?? '');
    final normalized = normalizeScriptHeaders(
      headers,
      host: true,
      bodyLength: bytes.length,
      requestUri: uri,
    );
    final reply = await _send(uri, verb, normalized, bytes);
    if (method != 'request' && (reply.code < 200 || reply.code >= 300)) {
      throw scriptFailure(reply.code == 403 ? 'http_forbidden' : 'http_status');
    }
    final text = utf8.decode(reply.bytes, allowMalformed: true);
    return method == 'request' ? {'code': reply.code, 'body': text} : text;
  }

  Future<ScriptHttpReply> _send(
    Uri uri,
    String verb,
    Map<String, String> headers,
    List<int> body, {
    bool source = false,
  }) async {
    validateScriptUri(uri);
    var credentialsAllowed = true;
    for (var redirect = 0; ; redirect++) {
      if (_closed) throw scriptFailure('cancelled');
      final sentHeaders = credentialsAllowed ? headers : <String, String>{};
      checkScriptBytes(uri.toString(), 65536);
      if (utf8.encode(uri.toString()).length +
              utf8.encode(jsonEncode(sentHeaders)).length +
              body.length >
          65536) {
        throw scriptFailure('resource_limit');
      }
      final reply = await _exchange(
        uri,
        verb,
        sentHeaders,
        body,
        source: source,
      );
      if (!const [301, 302, 303, 307, 308].contains(reply.code) ||
          reply.location == null) {
        return reply;
      }
      if (redirect == 5) throw scriptFailure('resource_limit');
      Uri next;
      try {
        next = uri.resolve(reply.location!);
      } on FormatException {
        throw scriptFailure('invalid_url');
      }
      validateScriptUri(next);
      if (uri.origin != next.origin) credentialsAllowed = false;
      uri = next;
      if (reply.code == 303 && verb != 'HEAD' ||
          (reply.code == 301 || reply.code == 302) && verb == 'POST') {
        verb = 'GET';
        body = const [];
      }
    }
  }

  void _count(int bytes, int current, bool source) {
    if (!source) _totalBytes += bytes;
    if (current > (source ? 524288 : 1048576) || _totalBytes > 4194304) {
      throw scriptFailure('resource_limit');
    }
  }

  Future<ScriptHttpReply> _exchange(
    Uri uri,
    String method,
    Map<String, String> headers,
    List<int> body, {
    required bool source,
  }) async {
    if (_fixture != null) {
      final reply = await _fixture(
        uri,
        method,
        Map.unmodifiable(headers),
        List.unmodifiable(body),
      );
      _count(reply.bytes.length, reply.bytes.length, source);
      return reply;
    }
    HttpClientRequest? request;
    try {
      request = await _client.openUrl(method, uri);
      _requests.add(request);
      if (_closed) {
        request.abort();
        throw scriptFailure('cancelled');
      }
      request.followRedirects = false;
      request.persistentConnection = false;
      headers.forEach((name, value) => request!.headers.set(name, value));
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
      request.contentLength = body.length;
      if (body.isNotEmpty) request.add(body);
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        _count(chunk.length, bytes.length + chunk.length, source);
        bytes.addAll(chunk);
      }
      return ScriptHttpReply(
        response.statusCode,
        bytes,
        location: response.headers.value(HttpHeaders.locationHeader),
      );
    } on YlScriptException {
      rethrow;
    } on Object {
      throw scriptFailure('transport');
    } finally {
      if (request != null) _requests.remove(request);
    }
  }
}
