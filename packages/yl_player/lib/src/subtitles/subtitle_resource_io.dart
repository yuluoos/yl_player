import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import '../drm/license_secure_socket.dart';
import 'subtitle_resource.dart';

// Each read owns its handles and a total deadline; no process-global client or
// file cache can keep credentials or old-session I/O alive.
Future<List<int>> read(
  YlMediaSource source,
  SubtitleCancellation token,
  int maxBytes,
) {
  final result = Completer<List<int>>();
  HttpClient? http;
  HttpClientRequest? request;
  StreamSubscription<List<int>>? body;
  final connecting = <void Function()>{};
  Timer? deadline;
  void cleanup() {
    deadline?.cancel();
    unawaited(body?.cancel());
    request?.abort();
    for (final close in connecting.toList()) {
      close();
    }
    connecting.clear();
    http?.close(force: true);
  }

  void fail(String code) {
    if (result.isCompleted) return;
    result.completeError(subtitleFailure(code));
    cleanup();
  }

  unawaited(token.cancelled.then((_) => fail(YlFailureCodes.loadCancelled)));
  deadline = Timer(
    const Duration(seconds: 30),
    () => fail(
      source is YlNetworkSource
          ? YlFailureCodes.networkFailed
          : YlFailureCodes.sourceInvalid,
    ),
  );
  Future<void> run() async {
    token.check();
    Stream<List<int>> stream;
    if (source is YlFileSource) {
      stream = File(source.path).openRead();
    } else if (source is YlNetworkSource) {
      final encodings = [
        ...source.request.headers.entries,
        ...source.request.credentials.entries,
      ].where((entry) => entry.key.toLowerCase() == 'accept-encoding');
      if (source.networkPolicy.kind != YlNetworkPolicyKind.platformDefault ||
          encodings.any(
            (entry) => entry.value.toLowerCase().trim() != 'identity',
          )) {
        fail(YlFailureCodes.policyUnsupported);
        return;
      }
      final client = HttpClient()..autoUncompress = false;
      http = client;
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, _, _) async {
        if (uri.scheme != 'https') {
          return Socket.startConnect(uri.host, uri.port);
        }
        final task = await RawSocket.startConnect(uri.host, uri.port);
        RawSocket? raw;
        var closed = false;
        void close() {
          closed = true;
          task.cancel();
          raw?.close();
        }

        connecting.add(close);
        if (result.isCompleted) close();
        final socket = task.socket.then<Socket>((value) async {
          raw = value;
          if (closed || result.isCompleted) {
            value.close();
            throw const SocketException('Cancelled');
          }
          try {
            // Raw socket ownership keeps a stalled TLS handshake cancellable.
            final secure = await RawSecureSocket.secure(value, host: uri.host);
            if (closed || result.isCompleted) {
              secure.close();
              throw const SocketException('Cancelled');
            }
            return YlLicenseSecureSocket(secure);
          } catch (_) {
            value.close();
            rethrow;
          } finally {
            connecting.remove(close);
          }
        });
        return ConnectionTask.fromSocket(socket, close);
      };
      var uri = source.uri;
      var stripped = false;
      var redirects = 0;
      while (true) {
        final current = await client.getUrl(uri);
        request = current;
        if (result.isCompleted) {
          current.abort();
          return;
        }
        current.followRedirects = false;
        current.maxRedirects = 0;
        source.request.headers.forEach(current.headers.set);
        if (!stripped) source.request.credentials.forEach(current.headers.set);
        current.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await current.close();
        if (result.isCompleted) return;
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value('location');
          if (location == null || location.length > 8192 || redirects++ >= 5) {
            fail(YlFailureCodes.networkFailed);
            return;
          }
          final next = uri.resolve(location);
          validateYlExternalSubtitles([
            YlExternalSubtitle(
              id: 'redirect',
              format: YlSubtitleFormat.srt,
              source: YlNetworkSource(next),
            ),
          ]);
          if (uri.scheme == 'https' && next.scheme != 'https') {
            fail(YlFailureCodes.networkFailed);
            return;
          }
          stripped |=
              next.scheme != uri.scheme ||
              next.host != uri.host ||
              next.port != uri.port;
          await response.listen((_) {}).cancel();
          uri = next;
          if (result.isCompleted) return;
          continue;
        }
        if (response.statusCode != 200) {
          fail(YlFailureCodes.networkFailed);
          return;
        }
        final encoding = response.headers.value('content-encoding');
        if (encoding != null && encoding.toLowerCase() != 'identity') {
          fail(YlFailureCodes.subtitleUnsupported);
          return;
        }
        if (response.contentLength > maxBytes) {
          fail(YlFailureCodes.subtitleTooLarge);
          return;
        }
        stream = response;
        break;
      }
    } else {
      fail(YlFailureCodes.subtitleUnsupported);
      return;
    }
    if (result.isCompleted) return;
    final bytes = BytesBuilder(copy: false);
    body = stream.listen(
      (chunk) {
        if (result.isCompleted) return;
        if (chunk.length > maxBytes - bytes.length) {
          fail(YlFailureCodes.subtitleTooLarge);
          return;
        }
        bytes.add(chunk);
      },
      onError: (Object _) => fail(
        source is YlNetworkSource
            ? YlFailureCodes.networkFailed
            : YlFailureCodes.sourceMissing,
      ),
      onDone: () {
        if (!result.isCompleted) result.complete(bytes.takeBytes());
      },
    );
  }

  unawaited(
    run().catchError((Object error) {
      fail(
        error is YlPlayerException
            ? error.failure.code
            : source is YlNetworkSource
            ? YlFailureCodes.networkFailed
            : YlFailureCodes.sourceMissing,
      );
    }),
  );
  return result.future.whenComplete(cleanup);
}
