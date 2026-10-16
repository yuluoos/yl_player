import 'dart:async';
import 'dart:io';
import 'package:yl_player/yl_player.dart';

enum DrmFault {
  denied(YlFailureCodes.drmLicenseDenied),
  timeout(YlFailureCodes.drmLicenseTimeout),
  cancel(YlFailureCodes.loadCancelled);

  const DrmFault(this.expectedCode);
  final String expectedCode;

  static DrmFault parse(String value) => switch (value) {
    'denied' => denied,
    'timeout' => timeout,
    'cancel' => cancel,
    _ => throw const FormatException('DRM fault selection is invalid.'),
  };
}

/// Test-only fault endpoint. Never forwards requests or retains challenge bytes,
/// URLs, headers or responses. A request counts only after a nonempty, bounded
/// binary POST has been consumed. It cannot issue a usable license.
final class DrmFaultServer {
  DrmFaultServer._(this.fault, this._server) {
    _server.listen(_handle, onError: (Object _) => _failed = true);
  }
  final DrmFault fault;
  final HttpServer _server;
  final _firstChallenge = Completer<void>();
  Future<void>? _closing;
  bool _failed = false;
  int requestCount = 0;
  int challengeCount = 0;
  Future<void> get firstChallenge => _firstChallenge.future;

  static Future<DrmFaultServer> start(DrmFault fault) async => DrmFaultServer._(
    fault,
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );

  YlDrmLicenseEndpoint endpoint({
    Duration timeout = const Duration(seconds: 2),
  }) => YlDrmLicenseEndpoint(
    Uri.parse('http://127.0.0.1:${_server.port}/license'),
    allowInsecureLoopback: true,
    timeout: timeout,
  );

  Future<void> _handle(HttpRequest request) async {
    requestCount++;
    try {
      if (_closing != null || requestCount > 4) {
        _failed = true;
        request.response.statusCode = 503;
        await request.response.close();
        return;
      }
      if (request.method != 'POST' ||
          request.uri.path != '/license' ||
          request.headers.contentType?.mimeType != 'application/octet-stream') {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      var size = 0;
      await for (final chunk in request.timeout(const Duration(seconds: 5))) {
        size += chunk.length;
        if (size > 1024 * 1024) break;
      }
      if (size == 0 || size > 1024 * 1024) {
        request.response.statusCode = size == 0 ? 400 : 413;
        await request.response.close();
        return;
      }
      challengeCount++;
      if (!_firstChallenge.isCompleted) _firstChallenge.complete();
      if (fault == DrmFault.denied) {
        request.response.statusCode = 403;
        await request.response.close();
      }
      // timeout/cancel deliberately withhold all response headers. Forced close
      // during teardown owns the connection; no stored request or license data.
    } on Object catch (_) {
      _failed = true;
    }
  }

  Map<String, Object> get report => {
    'fault': fault.name,
    'faultRequests': requestCount,
    'faultChallenges': challengeCount,
    'faultServerFailed': _failed,
    'faultUpstreamRequests': 0,
  };

  Future<void> close() => _closing ??= _server.close(force: true).then((_) {});
}
