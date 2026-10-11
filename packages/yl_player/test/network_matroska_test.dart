import 'dart:io';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/matroska_fixture.dart';
import 'support/ass_fixture.dart';
import 'package:yl_player/src/subtitles/subtitle_resource_io.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'support/range_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'managed HTTP discovers actual Matroska tracks and media-clock cues',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await RangeServer.start(mkv());
      final runtime = TextSubtitleRuntime();
      addTearDown(() async {
        runtime.reset();
        await server.close();
        HttpOverrides.global = previous;
      });
      await runtime.discover(
        YlNetworkSource(
          server.uri,
          networkPolicy: const YlNetworkPolicy.managed(),
        ),
      );
      expect(runtime.state.tracks.single.id, 'mkv:101');
      runtime.select('mkv:101');
      expect(
        runtime
            .cuesAt(const Duration(milliseconds: 1500))
            .single
            .text
            .toPlainText(),
        'hello',
      );
      expect(
        server.requests.single.headers.value('accept-encoding'),
        'identity',
      );
    },
  );
  group('range and policy', () {
    late HttpOverrides? previous;
    late SubtitleCancellation token;
    late TextSubtitleRuntime runtime;
    setUp(() {
      previous = HttpOverrides.current;
      HttpOverrides.global = null;
      token = SubtitleCancellation();
      runtime = TextSubtitleRuntime();
    });
    tearDown(() {
      token.cancel();
      runtime.reset();
      HttpOverrides.global = previous;
    });
    Future<RangeServer> serve([List<int>? bytes]) async {
      final server = await RangeServer.start(
        bytes ?? mkv(extra: element(0xec, List.filled(40000, 0))),
      );
      addTearDown(server.close);
      return server;
    }

    YlNetworkSource source(
      RangeServer server, {
      YlNetworkPolicy policy = const YlNetworkPolicy.managed(
        maxRetries: 2,
        baseRetryDelay: Duration.zero,
        maxRetryDelay: Duration.zero,
      ),
      YlHttpRequest? request,
    }) => YlNetworkSource(
      server.uri,
      format: YlMediaFormat.matroska,
      networkPolicy: policy,
      request: request,
    );
    Matcher failure(String code) => throwsA(
      isA<YlPlayerException>()
          .having((e) => e.failure.code, 'code', code)
          .having((e) => e.failure.scope, 'scope', YlFailureScope.command),
    );
    test(
      'sparse scan skips a large media-like payload and pins later ranges',
      () async {
        final server = await serve(
          mkv(extra: element(0xec, List.filled(5000000, 0))),
        );
        await runtime.discover(source(server));
        expect(server.requests.length, lessThan(8));
        expect(server.sent, lessThan(65536));
        expect(server.requests.first.headers.value('if-match'), isNull);
        for (final q in server.requests.skip(1)) {
          expect(q.headers.value('if-match'), '"owned-v1"');
        }
        runtime.select('mkv:101');
        expect(runtime.cuesAt(const Duration(seconds: 1)), hasLength(1));
      },
    );
    for (final ssa in [false, true]) {
      test(
        'network ${ssa ? 'SSA' : 'ASS'} retains styles, text and exact clock',
        () async {
          final server = await serve(
            mkv(
              tracks: track(
                codec: ssa ? 'S_TEXT/SSA' : 'S_TEXT/ASS',
                private: assFixture(ssa: ssa).split('[Events]').first,
              ),
              clusters: cluster(
                block(
                  time: 3,
                  duration: 107,
                  text: '0,${ssa ? '' : '0'},Default,,0,0,0,,{\\b1}owned',
                ),
              ),
            ),
          );
          await runtime.discover(source(server));
          runtime.select('mkv:101');
          expect(runtime.cuesAt(const Duration(milliseconds: 1002)), isEmpty);
          final cue = runtime.cuesAt(const Duration(milliseconds: 1003)).single;
          expect(cue.cue.ass!.runs.first.style.bold, true);
          expect(cue.text.toPlainText(), 'owned');
          expect(runtime.cuesAt(const Duration(milliseconds: 1110)), isEmpty);
        },
      );
    }
    test('valid CodecPrivate above 64 KiB spans range windows', () async {
      final header =
          assFixture().split('[Events]').first +
          List.filled(600, ';${'x' * 120}\n').join();
      final server = await serve(
        mkv(
          tracks: track(codec: 'S_TEXT/ASS', private: header),
          clusters: cluster(block(text: '0,0,Default,,0,0,0,,large header')),
        ),
      );
      await runtime.discover(source(server));
      runtime.select('mkv:101');
      expect(
        runtime.cuesAt(const Duration(seconds: 1)).single.text.toPlainText(),
        'large header',
      );
    });
    for (final mode in [
      '200',
      'missing-etag',
      'weak-etag',
      'bad-etag',
      'missing-range',
      'wrong-start',
      'wrong-end',
      'unknown-total',
      'compressed',
      'multipart',
      'short-body',
      'extra-body',
    ]) {
      test(
        'rejects invalid range response $mode without retry or publication',
        () async {
          final server = await serve(mkv());
          server.handle = (q, n) {
            if (mode == 'compressed') {
              q.response.headers.set('content-encoding', 'gzip');
            }
            if (mode == 'multipart') {
              q.response.headers.set(
                'content-type',
                'multipart/byteranges; boundary=owned',
              );
            }
            server.reply(
              q,
              status: mode == '200' ? 200 : null,
              etag: switch (mode) {
                'missing-etag' => null,
                'weak-etag' => 'W/"v1"',
                'bad-etag' => 'invalid',
                _ => '"owned-v1"',
              },
              contentRange: switch (mode) {
                'missing-range' => '',
                'wrong-start' =>
                  'bytes 1-${server.bytes.length - 1}/${server.bytes.length}',
                'wrong-end' => 'bytes 0-2/${server.bytes.length}',
                'unknown-total' => 'bytes 0-2/*',
                _ => null,
              },
              body: mode == 'short-body'
                  ? server.bytes.sublist(0, server.bytes.length - 1)
                  : mode == 'extra-body'
                  ? [...server.bytes, 0]
                  : null,
              chunked: mode == 'short-body' || mode == 'extra-body',
            );
          };
          await expectLater(
            runtime.discover(source(server)),
            throwsA(isA<YlPlayerException>()),
          );
          expect(server.requests, hasLength(1));
          expect(runtime.state.tracks, isEmpty);
        },
      );
    }
    for (final change in ['etag', 'length', '412', 'redirect']) {
      test(
        'later $change invalidates candidate and keeps old selected catalog',
        () async {
          final server = await serve();
          await runtime.discover(source(server));
          runtime.select('mkv:101');
          final old = runtime.state;
          var calls = 0;
          server.handle = (q, n) {
            calls++;
            if (calls > 1 && change == '412') {
              q.response.statusCode = 412;
              unawaited(q.response.close());
              return;
            }
            if (calls > 1 && change == 'redirect') {
              q.response.statusCode = 302;
              q.response.headers.set('location', '/different');
              unawaited(q.response.close());
              return;
            }
            final (start, end) = server.range(q);
            final last = end.clamp(0, server.bytes.length - 1);
            server.reply(
              q,
              etag: calls > 1 && change == 'etag' ? '"v2"' : '"owned-v1"',
              contentRange: calls > 1 && change == 'length'
                  ? 'bytes $start-$last/${server.bytes.length + 1}'
                  : null,
            );
          };
          await expectLater(
            runtime.discover(source(server)),
            throwsA(isA<YlPlayerException>()),
          );
          expect(calls, 2);
          expect(runtime.state, old);
          expect(runtime.cuesAt(const Duration(seconds: 1)), hasLength(1));
        },
      );
    }
    test(
      'cross-origin credentials stay stripped on retry and later windows',
      () async {
        final origin = await serve();
        final destination = await serve();
        var calls = 0;
        origin.handle = (q, n) {
          q.response.statusCode = 302;
          q.response.headers.set('location', destination.uri.toString());
          unawaited(q.response.close());
        };
        destination.handle = (q, n) {
          if (++calls == 1) {
            q.response.statusCode = 503;
            unawaited(q.response.close());
          } else {
            destination.reply(q);
          }
        };
        await runtime.discover(
          source(
            origin,
            request: YlHttpRequest(
              headers: {'X-Ordinary': 'kept'},
              credentials: {
                'Authorization': 'Bearer private',
                'Cookie': 'private',
              },
            ),
          ),
        );
        expect(
          origin.requests.single.headers.value('authorization'),
          'Bearer private',
        );
        expect(destination.requests.length, greaterThan(2));
        for (final q in destination.requests) {
          expect(q.headers.value('authorization'), isNull);
          expect(q.headers.value('cookie'), isNull);
          expect(q.headers.value('x-ordinary'), 'kept');
        }
      },
    );
    test('retry budget is shared across distinct range windows', () async {
      final server = await serve();
      final counts = <String, int>{};
      server.handle = (q, n) {
        final key = q.headers.value('range')!;
        counts[key] = (counts[key] ?? 0) + 1;
        if (counts[key] == 1) {
          q.response.statusCode = 503;
          unawaited(q.response.close());
        } else {
          server.reply(q);
        }
      };
      await expectLater(
        runtime.discover(
          source(
            server,
            policy: const YlNetworkPolicy.managed(
              maxRetries: 1,
              baseRetryDelay: Duration.zero,
            ),
          ),
        ),
        failure(YlFailureCodes.networkFailed),
      );
      expect(server.requests, hasLength(3));
      expect(counts.values.toList(), [2, 1]);
    });
    test(
      'redirect budget spans retries before representation is pinned',
      () async {
        final server = await serve();
        var calls = 0;
        server.handle = (q, n) {
          calls++;
          if (calls == 2) {
            q.response.statusCode = 503;
          } else {
            q.response.statusCode = 302;
            q.response.headers.set('location', '/hop$calls');
          }
          unawaited(q.response.close());
        };
        await expectLater(
          runtime.discover(
            source(
              server,
              policy: const YlNetworkPolicy.managed(
                maxRetries: 2,
                maxRedirects: 1,
                baseRetryDelay: Duration.zero,
              ),
            ),
          ),
          failure(YlFailureCodes.networkFailed),
        );
        expect(calls, 3);
      },
    );
    for (final status in [408, 429, 500, 502, 503, 504]) {
      test('retryable HTTP $status retains requested byte interval', () async {
        final server = await serve(mkv());
        server.handle = (q, n) {
          if (n == 1) {
            q.response.statusCode = status;
            q.response.headers.set('retry-after', '0');
            unawaited(q.response.close());
          } else {
            server.reply(q);
          }
        };
        await runtime.discover(source(server));
        expect(server.requests, hasLength(2));
        expect(
          server.requests.first.headers.value('range'),
          server.requests.last.headers.value('range'),
        );
      });
    }
    for (final status in [400, 401, 403, 404, 412, 416, 501]) {
      test('permanent HTTP $status does not retry', () async {
        final server = await serve();
        server.handle = (q, n) {
          q.response.statusCode = status;
          unawaited(q.response.close());
        };
        await expectLater(
          runtime.discover(source(server)),
          failure(YlFailureCodes.networkFailed),
        );
        expect(server.requests, hasLength(1));
      });
    }
    test(
      'excessive Retry-After is terminal and cancellation interrupts backoff',
      () async {
        final server = await serve();
        server.handle = (q, n) {
          q.response.statusCode = 503;
          q.response.headers.set('retry-after', '60');
          unawaited(q.response.close());
        };
        await expectLater(
          runtime.discover(source(server)),
          failure(YlFailureCodes.networkFailed),
        );
        expect(server.requests, hasLength(1));
        final arrived = Completer<void>();
        server.handle = (q, n) {
          q.response.statusCode = 503;
          q.response.headers.set('retry-after', '5');
          unawaited(
            q.response.close().then((_) {
              if (!arrived.isCompleted) arrived.complete();
            }),
          );
        };
        final pending = runtime.discover(
          source(
            server,
            policy: const YlNetworkPolicy.managed(
              maxRetryDelay: Duration(seconds: 8),
            ),
          ),
        );
        final rejected = expectLater(
          pending,
          failure(YlFailureCodes.loadCancelled),
        );
        await arrived.future;
        runtime.cancel();
        await rejected;
        expect(server.requests, hasLength(2));
      },
    );
    test('header deadline retries the same range', () async {
      final server = await serve(mkv());
      server.handle = (q, n) {
        if (n > 1) server.reply(q);
      };
      await runtime.discover(
        source(
          server,
          policy: const YlNetworkPolicy.managed(
            connectTimeout: Duration(milliseconds: 100),
            maxRetries: 1,
            baseRetryDelay: Duration.zero,
          ),
        ),
      );
      expect(server.requests, hasLength(2));
    });
    test(
      'body inactivity retries from scratch and drops partial bytes',
      () async {
        final server = await serve(mkv());
        server.handle = (q, n) async {
          if (n > 1) {
            server.reply(q);
            return;
          }
          q.response.statusCode = 206;
          q.response.headers.set(
            'content-range',
            'bytes 0-${server.bytes.length - 1}/${server.bytes.length}',
          );
          q.response.headers.set('etag', '"owned-v1"');
          q.response.contentLength = server.bytes.length;
          q.response.bufferOutput = false;
          q.response.add([99]);
          await q.response.flush();
        };
        await runtime.discover(
          source(
            server,
            policy: const YlNetworkPolicy.managed(
              readTimeout: Duration(milliseconds: 100),
              maxRetries: 1,
              baseRetryDelay: Duration.zero,
            ),
          ),
        );
        expect(server.requests, hasLength(2));
        expect(runtime.state.tracks.single.id, 'mkv:101');
      },
    );
    test('body progress resets inactivity after header deadline', () async {
      final server = await serve(mkv());
      server.handle = (q, n) async {
        q.response.statusCode = 206;
        q.response.headers.set(
          'content-range',
          'bytes 0-${server.bytes.length - 1}/${server.bytes.length}',
        );
        q.response.headers.set('etag', '"owned-v1"');
        q.response.contentLength = server.bytes.length;
        q.response.bufferOutput = false;
        for (var i = 0; i < server.bytes.length; i += 30) {
          q.response.add(
            server.bytes.sublist(i, (i + 30).clamp(0, server.bytes.length)),
          );
          await q.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 35));
        }
        await q.response.close();
      };
      await runtime.discover(
        source(
          server,
          policy: const YlNetworkPolicy.managed(
            connectTimeout: Duration(milliseconds: 100),
            readTimeout: Duration(milliseconds: 120),
            maxRetries: 0,
          ),
        ),
      );
      expect(server.requests, hasLength(1));
    });
    test('platformDefault supports range but does not retry', () async {
      final server = await serve(mkv());
      await runtime.discover(
        source(server, policy: const YlNetworkPolicy.platformDefault()),
      );
      server.handle = (q, n) {
        q.response.statusCode = 503;
        unawaited(q.response.close());
      };
      await expectLater(
        runtime.discover(
          source(server, policy: const YlNetworkPolicy.platformDefault()),
        ),
        failure(YlFailureCodes.networkFailed),
      );
      expect(server.requests, hasLength(2));
    });
    for (final header in [
      'If-Match',
      'If-Range',
      'If-None-Match',
      'If-Modified-Since',
      'If-Unmodified-Since',
      'Accept-Encoding',
    ]) {
      test('conflicting $header is rejected before I/O', () async {
        final server = await serve();
        await expectLater(
          runtime.discover(
            source(
              server,
              request: YlHttpRequest(headers: {header: 'unsupported'}),
            ),
          ),
          failure(YlFailureCodes.policyUnsupported),
        );
        expect(server.requests, isEmpty);
      });
    }
    test('LRU cache is bounded and refetch preserves If-Match', () async {
      final server = await serve(List.filled(130 * 16384, 0));
      final reader = await SubtitleRangeReader.open(source(server), token);
      for (var i = 1; i < 130; i++) {
        await reader.read(i * 16384, 1);
      }
      expect(server.requests, hasLength(130));
      await reader.read(129 * 16384, 1);
      expect(server.requests, hasLength(130));
      await reader.read(0, 1);
      expect(server.requests, hasLength(131));
      expect(server.requests.last.headers.value('if-match'), '"owned-v1"');
      reader.clear();
    });

    test(
      '4096 HTTP-attempt cap bounds a repeated cache-thrashing scan',
      () async {
        final server = await serve(List.filled(129 * 16384, 0));
        final reader = await SubtitleRangeReader.open(source(server), token);
        for (var i = 1; i < 4096; i++) {
          await reader.read((i % 129) * 16384, 1);
        }
        expect(server.requests, hasLength(4096));
        await expectLater(
          reader.read((4096 % 129) * 16384, 1),
          failure(YlFailureCodes.subtitleTooLarge),
        );
        expect(server.requests, hasLength(4096));
        reader.clear();
      },
    );
    test(
      'cancelling held later range keeps published catalog and disposes candidate',
      () async {
        final server = await serve();
        await runtime.discover(source(server));
        runtime.select('mkv:101');
        final old = runtime.state;
        final held = Completer<HttpRequest>();
        var calls = 0;
        server.handle = (q, n) {
          if (++calls == 1) {
            server.reply(q);
          } else {
            held.complete(q);
          }
        };
        final pending = runtime.discover(source(server));
        final rejected = expectLater(
          pending,
          failure(YlFailureCodes.loadCancelled),
        );
        final q = await held.future;
        runtime.cancel();
        await rejected;
        server.reply(q);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(runtime.state, old);
      },
    );
  });
}
