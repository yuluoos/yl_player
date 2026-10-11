import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_source_resolver/yl_player_source_resolver.dart';

void main() {
  for (final download in [false, true]) {
    for (final body in [false, true]) {
      for (final stop in ['cancel', 'timeout', 'dispose']) {
        test(
          '${download ? 'download' : 'host'} held ${body ? 'body' : 'headers'} '
          '$stop closes peer socket and permits fresh resolution',
          () async {
            final peer = await _HeldPeer.start(body: body);
            final resolver = YlScriptResolver(
              limits: YlScriptLimits(
                timeout: Duration(seconds: stop == 'timeout' ? 1 : 10),
              ),
            );
            addTearDown(() async {
              // Release the peer first even if a broken abort leaves dispose
              // waiting on its HTTP exchange after a test assertion fails.
              await peer.close();
              await resolver.dispose();
            });
            final bodyReceived = Completer<void>();
            final job = HttpOverrides.runWithHttpOverrides(
              () => download
                  ? resolver.resolve(
                      YlScriptReference(scriptUri: peer.uri, parameters: ''),
                    )
                  : resolver.resolveSource(
                      'function main(){return {url:mytv.get("${peer.uri}")}}',
                    ),
              _BodyObserver(bodyReceived),
            );
            final checked = expectLater(
              job.result,
              throwsA(
                isA<YlScriptException>().having(
                  (error) => error.code,
                  'code',
                  stop == 'timeout' ? 'script.timeout' : 'script.cancelled',
                ),
              ),
            );
            // Observe the real client body stream, not just server flush.
            await peer.started.future.timeout(const Duration(seconds: 5));
            if (body) {
              await bodyReceived.future.timeout(const Duration(seconds: 5));
            }
            expect(peer.disconnected.isCompleted, isFalse);
            switch (stop) {
              case 'cancel':
                await job.cancel().timeout(const Duration(seconds: 5));
              case 'dispose':
                await resolver.dispose().timeout(const Duration(seconds: 5));
              case 'timeout':
                break;
            }
            await checked.timeout(const Duration(seconds: 5));
            // The peer never closes its socket until tearDown. EOF/reset must
            // therefore come from the resolver, not fixture cleanup.
            await peer.disconnected.future.timeout(const Duration(seconds: 5));
            expect(peer.requests, 1);

            final next = stop == 'dispose' ? YlScriptResolver() : resolver;
            if (stop == 'dispose') addTearDown(next.dispose);
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            server.listen((request) async {
              request.response.write('https://fixture.invalid/fresh');
              await request.response.close();
            });
            final fresh = await next
                .resolveSource(
                  'function main(){return {url:mytv.get('
                  '"http://127.0.0.1:${server.port}/fresh")}}',
                )
                .result
                .timeout(const Duration(seconds: 5));
            expect(fresh.uri.path, '/fresh');
          },
        );
      }
    }
  }
}

/// A raw peer lets tests observe client EOF/reset while keeping the response
/// intentionally unfinished; HttpResponse.done alone is not that evidence.
final class _HeldPeer {
  _HeldPeer(this.server, {required this.body}) {
    server.listen((socket) {
      sockets.add(socket);
      final bytes = <int>[];
      var receivedHeaders = false;
      socket.listen(
        (data) async {
          bytes.addAll(data);
          if (receivedHeaders || !ascii.decode(bytes).contains('\r\n\r\n')) {
            return;
          }
          receivedHeaders = true;
          requests++;
          if (body) {
            socket.write(
              'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
              '4\r\nheld\r\n',
            );
            await socket.flush();
          }
          if (!started.isCompleted) started.complete();
        },
        onDone: _disconnected,
        onError: (Object error) {
          if (error is SocketException) {
            _disconnected();
          } else if (!disconnected.isCompleted) {
            disconnected.completeError(error);
          }
        },
      );
    });
  }

  final ServerSocket server;
  final bool body;
  final sockets = <Socket>[];
  final started = Completer<void>();
  final disconnected = Completer<void>();
  int requests = 0;

  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/held');

  static Future<_HeldPeer> start({required bool body}) async => _HeldPeer(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    body: body,
  );

  void _disconnected() {
    if (!disconnected.isCompleted) disconnected.complete();
  }

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  }
}

// Forward only the transport members exercised by ScriptHttp, failing loudly
// if that contract changes. All socket/HTTP work still uses dart:io's client.
final class _BodyObserver extends HttpOverrides {
  _BodyObserver(this.received);
  final Completer<void> received;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _ObservedClient(super.createHttpClient(context), received);
}

final class _ObservedClient implements HttpClient {
  _ObservedClient(this.client, this.received);
  final HttpClient client;
  final Completer<void> received;

  @override
  set findProxy(String Function(Uri)? value) => client.findProxy = value;
  @override
  set autoUncompress(bool value) => client.autoUncompress = value;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _ObservedRequest(await client.openUrl(method, url), received);
  @override
  void close({bool force = false}) => client.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ObservedRequest implements HttpClientRequest {
  _ObservedRequest(this.request, this.received);
  final HttpClientRequest request;
  final Completer<void> received;

  @override
  HttpHeaders get headers => request.headers;
  @override
  set followRedirects(bool value) => request.followRedirects = value;
  @override
  set persistentConnection(bool value) => request.persistentConnection = value;
  @override
  set contentLength(int value) => request.contentLength = value;
  @override
  void add(List<int> data) => request.add(data);
  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      request.abort(exception, stackTrace);
  @override
  Future<HttpClientResponse> close() async =>
      _ObservedResponse(await request.close(), received);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ObservedResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _ObservedResponse(this.response, this.received);
  final HttpClientResponse response;
  final Completer<void> received;

  @override
  HttpHeaders get headers => response.headers;
  @override
  int get statusCode => response.statusCode;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => response
      .map((chunk) {
        if (chunk.isNotEmpty && !received.isCompleted) received.complete();
        return chunk;
      })
      .listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
