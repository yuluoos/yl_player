import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'license_client.dart';
import 'license_secure_socket.dart';

Future<YlDrmBytes> sendLicense(
  YlDrmLicenseEndpoint endpoint,
  YlDrmBytes challenge,
  YlDrmCancellationToken cancellation, {
  // Internal fixture seam only. Public clients always use system trust.
  SecurityContext? securityContext,
}) {
  final result = Completer<YlDrmBytes>();
  final http = HttpClient()..autoUncompress = false;
  final shutdowns = <void Function()>{};
  http.findProxy = (_) => 'DIRECT';
  http.connectionFactory = (uri, proxyHost, proxyPort) async {
    if (uri.scheme != 'https') return Socket.startConnect(uri.host, uri.port);
    // Own TCP through the TLS handshake. SecureSocket.startConnect in Dart 3.12
    // cannot cancel a stalled handshake once its TCP task has completed.
    final task = await RawSocket.startConnect(uri.host, uri.port);
    RawSocket? raw;
    var cancelled = false;
    void cancel() {
      if (cancelled) return;
      cancelled = true;
      task.cancel();
      raw?.close();
    }

    shutdowns.add(cancel);
    final future = task.socket.then<Socket>((socket) async {
      raw = socket;
      if (cancelled || result.isCompleted) {
        socket.close();
        throw const SocketException('Cancelled');
      }
      try {
        final secure = await RawSecureSocket.secure(
          socket,
          host: uri.host,
          context: securityContext,
        );
        if (cancelled || result.isCompleted) {
          secure.close();
          throw const SocketException('Cancelled');
        }
        return YlLicenseSecureSocket(secure);
      } catch (_) {
        socket.close();
        rethrow;
      } finally {
        shutdowns.remove(cancel);
      }
    });
    if (result.isCompleted) cancel();
    return ConnectionTask.fromSocket(future, cancel);
  };
  void closeConnections() {
    final pending = shutdowns.toList();
    shutdowns.clear();
    for (final cancel in pending) {
      cancel();
    }
    http.close(force: true);
  }

  HttpClientRequest? current;
  Timer? deadline;
  void fail(String code) {
    if (result.isCompleted) return;
    result.completeError(ylDrmException(code));
    current?.abort();
    closeConnections();
  }

  final remove = cancellation.listen(() => fail(YlFailureCodes.loadCancelled));
  deadline = Timer(
    endpoint.timeout,
    () => fail(YlFailureCodes.drmLicenseTimeout),
  );
  bool active() => !result.isCompleted;
  Future<void> run() async {
    var retries = 0;
    var redirects = 0;
    var uri = endpoint.uri;
    final visited = <Uri>{uri};
    while (active()) {
      try {
        final request = await http.postUrl(uri);
        current = request;
        if (!active()) {
          request.abort();
          return;
        }
        request.followRedirects = false;
        request.maxRedirects = 0;
        request.headers.contentType = ContentType(
          'application',
          'octet-stream',
        );
        request.headers.set('accept-encoding', 'identity');
        endpoint.request.headers.forEach(request.headers.set);
        endpoint.request.credentials.forEach(request.headers.set);
        request.contentLength = challenge.length;
        request.add(challenge.bytes);
        final response = await request.close();
        if (!active()) return;
        final status = response.statusCode;
        if (status >= 300 && status < 400) {
          final location = response.headers.value('location');
          Uri? next;
          try {
            if (location != null && location.length <= 8192) {
              next = uri.resolve(location);
            }
          } catch (_) {
            /* reject without echo */
          }
          final sameOrigin =
              next != null &&
              next.scheme == endpoint.uri.scheme &&
              next.host == endpoint.uri.host &&
              next.port == endpoint.uri.port &&
              next.userInfo.isEmpty &&
              !next.hasFragment;
          if (!endpoint.allowSameOriginRedirects ||
              (status != 307 && status != 308) ||
              !sameOrigin ||
              redirects >= 2 ||
              visited.contains(next)) {
            fail(YlFailureCodes.drmLicenseRedirectRejected);
            return;
          }
          // Do not buffer/drain unbounded error/redirect bodies.
          await response.listen((_) {}).cancel();
          if (!active()) return;
          uri = next;
          visited.add(uri);
          redirects++;
          continue;
        }
        if (status != 200) {
          await response.listen((_) {}).cancel();
          if (!active()) return;
          if ([502, 503, 504].contains(status) &&
              endpoint.replay == YlDrmPostReplay.explicitlyIdempotent &&
              retries < endpoint.maxRetries) {
            retries++;
            continue;
          }
          fail(
            status == 401 || status == 403
                ? YlFailureCodes.drmLicenseDenied
                : YlFailureCodes.drmLicenseFailed,
          );
          return;
        }
        final encoding = response.headers.value('content-encoding');
        if (encoding != null && encoding.toLowerCase() != 'identity') {
          fail(YlFailureCodes.drmLicenseResponseInvalid);
          return;
        }
        if (response.contentLength > endpoint.maxResponseBytes) {
          fail(YlFailureCodes.drmPayloadTooLarge);
          return;
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (!active()) return;
          if (chunk.length > endpoint.maxResponseBytes - bytes.length) {
            fail(YlFailureCodes.drmPayloadTooLarge);
            return;
          }
          bytes.add(chunk);
        }
        if (!active()) return;
        if (bytes.isEmpty) {
          fail(YlFailureCodes.drmLicenseResponseInvalid);
          return;
        }
        result.complete(YlDrmBytes(bytes.takeBytes()));
        return;
      } catch (_) {
        if (!active()) return;
        if (endpoint.replay == YlDrmPostReplay.explicitlyIdempotent &&
            retries < endpoint.maxRetries) {
          retries++;
          continue;
        }
        fail(YlFailureCodes.drmLicenseFailed);
        return;
      }
    }
  }

  unawaited(
    run().whenComplete(() {
      deadline?.cancel();
      remove();
      closeConnections();
    }),
  );
  // Close immediately even when connect/response-body futures haven't settled.
  return result.future.whenComplete(() {
    deadline?.cancel();
    remove();
    closeConnections();
  });
}
