import 'dart:convert';

import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

/// Safe fixed classifications; no untrusted text is retained in an exception.
final class YlScriptException implements Exception {
  const YlScriptException._(
    this.code,
    this.message,
    this.retryable,
    this.phase,
    this.diagnosticId,
  );

  final String code;
  final String message;
  final bool retryable;
  final String diagnosticId;
  final String phase;
  String get scope => 'sourceResolver';

  @override
  String toString() =>
      'YlScriptException($code, $phase, $diagnosticId: $message)';
}

int _diagnosticSequence = 0;
String createScriptDiagnosticId() =>
    'script-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${++_diagnosticSequence}';

YlScriptException withScriptFailureContext(
  YlScriptException failure,
  String id,
  String phase,
) => YlScriptException._(
  failure.code,
  failure.message,
  failure.retryable,
  phase,
  id,
);

YlScriptException scriptFailure(String kind) {
  final (message, retryable) = switch (kind) {
    'cancelled' => ('解析已取消。', false),
    'timeout' => ('解析超时，请稍后重试。', true),
    'resource_limit' => ('解析超出资源限制，请检查脚本或缩小输入。', false),
    'invalid_url' => ('地址无效或协议不受支持，请检查输入。', false),
    'invalid_headers' => ('请求头无效，请检查脚本输出。', false),
    'invalid_result' => ('脚本未返回有效播放结果，请检查脚本。', false),
    'reported_error' => ('脚本报告解析失败，请检查源配置。', false),
    'expired' => ('播放地址已过期，请重新解析。', true),
    'media_protocol_unsupported' => ('播放器暂不支持此媒体协议。', false),
    'host_api_unsupported' => ('脚本使用了不支持的宿主接口。', false),
    'http_forbidden' => ('服务器拒绝访问，请检查权限或源配置。', false),
    'http_status' => ('服务器返回失败状态，请检查源配置后重试。', true),
    'transport' => ('网络请求失败，请检查网络后重试。', true),
    'syntax' => ('脚本语法无效，请检查脚本。', false),
    'disposed' => ('解析器已关闭，请创建新的解析器。', false),
    'invalid_limits' => ('解析资源限制配置无效。', false),
    _ => ('脚本执行失败，原因未知，请检查脚本。', false),
  };
  return YlScriptException._(
    'script.$kind',
    message,
    retryable,
    'input',
    createScriptDiagnosticId(),
  );
}

final class YlScriptLimits {
  const YlScriptLimits({
    this.timeout = const Duration(seconds: 10),
    this.heapBytes = 16 * 1024 * 1024,
    this.stackBytes = 512 * 1024,
  });

  final Duration timeout;
  final int heapBytes;
  final int stackBytes;

  void validate() {
    if (timeout.inMilliseconds < 1 ||
        timeout.inMicroseconds > 30000000 ||
        heapBytes < 8 * 1024 * 1024 ||
        heapBytes > 64 * 1024 * 1024 ||
        stackBytes < 256 * 1024 ||
        stackBytes > 1024 * 1024) {
      throw scriptFailure('invalid_limits');
    }
  }
}

final class YlScriptReference {
  YlScriptReference({
    required this.scriptUri,
    required this.parameters,
    Map<String, String> headers = const {},
  }) : headers = Map.unmodifiable(normalizeScriptHeaders(headers)) {
    validateScriptUri(scriptUri);
    checkScriptBytes(parameters, 8192);
  }

  factory YlScriptReference.parse(String reference) {
    if (reference.length > 512 * 1024 ||
        !reference.startsWith('javascript://')) {
      throw scriptFailure('invalid_url');
    }
    final raw = reference.substring(13);
    if (raw.contains('#')) throw scriptFailure('invalid_url');
    final separator = raw.indexOf('?');
    try {
      return YlScriptReference(
        scriptUri: Uri.parse(separator < 0 ? raw : raw.substring(0, separator)),
        parameters: separator < 0 ? '' : raw.substring(separator + 1),
      );
    } on FormatException {
      throw scriptFailure('invalid_url');
    }
  }

  final Uri scriptUri;
  final String parameters;
  final Map<String, String> headers;

  @override
  String toString() => 'YlScriptReference(<redacted>)';
}

final class YlResolvedSource {
  YlResolvedSource._(this.uri, Map<String, String> headers, this.expiresAt)
    : headers = Map.unmodifiable(headers);

  final Uri uri;
  final Map<String, String> headers;
  final DateTime? expiresAt;

  /// Converts HTTP(S) or header-free RTMP results. RTMPS stays unsupported;
  /// RTMP syntax is checked by the core source validator before native routing.
  YlNetworkSource toNetworkSource() {
    if (uri.scheme != 'http' && uri.scheme != 'https' && uri.scheme != 'rtmp') {
      throw scriptFailure('media_protocol_unsupported');
    }
    checkExpiry(expiresAt);
    if (uri.scheme == 'rtmp' && headers.isNotEmpty) {
      throw scriptFailure('invalid_headers');
    }
    final source = YlNetworkSource(
      uri,
      intent: YlStreamIntent.live,
      request: YlHttpRequest(credentials: headers),
    );
    if (uri.scheme == 'rtmp') {
      try {
        validateYlSource(source);
      } on ArgumentError {
        throw scriptFailure('invalid_url');
      }
    }
    return source;
  }

  @override
  String toString() => 'YlResolvedSource(<redacted>)';
}

void checkScriptBytes(String text, int limit) {
  if (text.length > limit || utf8.encode(text).length > limit) {
    throw scriptFailure('resource_limit');
  }
}

void validateScriptUri(Uri uri, {bool media = false}) {
  if (!(media
              ? const ['http', 'https', 'rtmp', 'rtmps']
              : const ['http', 'https'])
          .contains(uri.scheme) ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.authority.contains('@') ||
      uri.hasFragment ||
      uri.toString().contains(RegExp(r'[\x00-\x20\x7f]'))) {
    throw scriptFailure('invalid_url');
  }
}

Map<String, String> normalizeScriptHeaders(
  Object? input, {
  bool host = false,
  int? bodyLength,
  Uri? requestUri,
}) {
  if (input == null || input == '') return {};
  final entries = <MapEntry<String, String>>[];
  if (input is Map) {
    for (final entry in input.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw scriptFailure('invalid_headers');
      }
      entries.add(MapEntry(entry.key as String, entry.value as String));
    }
  } else {
    final Object lines = input is String ? input.split('\n') : input;
    if (lines is! List) throw scriptFailure('invalid_headers');
    for (final line in lines) {
      if (line is! String || line.contains('\r') || line.contains('\n')) {
        throw scriptFailure('invalid_headers');
      }
      final split = line.indexOf(':');
      if (split < 1) throw scriptFailure('invalid_headers');
      entries.add(
        MapEntry(line.substring(0, split), line.substring(split + 1)),
      );
    }
  }
  final result = <String, String>{};
  for (final entry in entries) {
    final key = entry.key.toLowerCase();
    final value = entry.value.trim();
    if (!RegExp(r"^[!#$%&'*+.^_`|~0-9a-z-]+$").hasMatch(key) ||
        entry.value.contains(RegExp(r'[\x00-\x08\x0a-\x1f\x7f]')) ||
        const [
          'connection',
          'transfer-encoding',
          'upgrade',
          'te',
          'trailer',
          'proxy-authorization',
          'proxy-connection',
          'keep-alive',
        ].contains(key)) {
      throw scriptFailure('invalid_headers');
    }
    if (result.containsKey(key) && result[key] != value) {
      throw scriptFailure('invalid_headers');
    }
    result[key] = value;
  }
  if (result.containsKey('host')) {
    final supplied = result.remove('host')!;
    if (!host || requestUri == null || supplied.contains(RegExp(r'[/@?#\s]'))) {
      throw scriptFailure('invalid_headers');
    }
    // Uri canonicalization removes explicit default ports. Preserve whether the
    // header spelled a port before parsing so ':80' cannot masquerade as absent.
    final explicitPort = supplied.startsWith('[')
        ? !supplied.endsWith(']')
        : supplied.contains(':');
    if (explicitPort && !RegExp(r':\d+$').hasMatch(supplied)) {
      throw scriptFailure('invalid_headers');
    }
    final authority = Uri.tryParse('${requestUri.scheme}://$supplied');
    if (authority == null ||
        authority.host.toLowerCase() != requestUri.host.toLowerCase() ||
        (explicitPort && authority.port != requestUri.port) ||
        authority.path.isNotEmpty ||
        authority.hasQuery ||
        authority.hasFragment) {
      throw scriptFailure('invalid_headers');
    }
  }
  if (result.containsKey('content-length')) {
    final value = result.remove('content-length')!;
    if (!host ||
        !RegExp(r'^\d+$').hasMatch(value) ||
        int.tryParse(value) != bodyLength) {
      throw scriptFailure('invalid_headers');
    }
  }
  if (host) result.remove('accept-encoding');
  checkScriptBytes(jsonEncode(result), 65536);
  return result;
}

void checkExpiry(DateTime? expiry) {
  if (expiry != null && !expiry.isAfter(DateTime.now().toUtc())) {
    throw scriptFailure('expired');
  }
}

YlResolvedSource normalizeScriptResult(String? json) {
  if (json == null) throw scriptFailure('invalid_result');
  checkScriptBytes(json, 65536);
  Object? value;
  try {
    value = jsonDecode(json);
    if (value is String) value = jsonDecode(value);
  } on FormatException {
    throw scriptFailure('invalid_result');
  }
  if (value is! Map) throw scriptFailure('invalid_result');
  final error = value['error'];
  if (error != null && error != false && error != '' && error != 0) {
    throw scriptFailure('reported_error');
  }
  final url = value['url'];
  if (url is! String || url.isEmpty) throw scriptFailure('invalid_result');
  final uri = Uri.tryParse(url);
  if (uri == null) throw scriptFailure('invalid_url');
  validateScriptUri(uri, media: true);
  DateTime? expiry;
  if (value.containsKey('expiresAt')) {
    final raw = value['expiresAt'];
    if (raw is! String ||
        !RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$',
        ).hasMatch(raw)) {
      throw scriptFailure('invalid_result');
    }
    expiry = DateTime.tryParse(raw);
    if (expiry == null ||
        !expiry.isUtc ||
        expiry.year != int.parse(raw.substring(0, 4)) ||
        expiry.month != int.parse(raw.substring(5, 7)) ||
        expiry.day != int.parse(raw.substring(8, 10)) ||
        expiry.hour != int.parse(raw.substring(11, 13)) ||
        expiry.minute != int.parse(raw.substring(14, 16)) ||
        expiry.second != int.parse(raw.substring(17, 19))) {
      throw scriptFailure('invalid_result');
    }
    checkExpiry(expiry);
  }
  return YlResolvedSource._(
    uri,
    normalizeScriptHeaders(value['headers']),
    expiry,
  );
}
