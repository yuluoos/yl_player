import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import '../drm/license_secure_socket.dart';
import 'subtitle_resource.dart';
import 'subtitle_socket.dart';

part 'subtitle_range_reader.dart';

Future<List<int>> read(
  YlMediaSource source,
  SubtitleCancellation token,
  int maxBytes,
) async {
  validateYlSource(source);
  token.check();
  final owned = SubtitleCancellation();
  final remove = token.listen(owned.cancel);
  try {
    final Future<List<int>> operation;
    final bool managed;
    if (source is YlFileSource) {
      managed = false;
      operation = _Attempt(
        owned,
        maxBytes,
      ).file(source.path).then((r) => r.bytes!);
    } else if (source is YlNetworkSource &&
        ['http', 'https'].contains(source.uri.scheme)) {
      managed = source.networkPolicy.kind == YlNetworkPolicyKind.managed;
      final encodings = [
        ...source.request.headers.entries,
        ...source.request.credentials.entries,
      ].where((entry) => entry.key.toLowerCase() == 'accept-encoding');
      if (encodings.any(
        (entry) => entry.value.toLowerCase().trim() != 'identity',
      )) {
        throw subtitleFailure(YlFailureCodes.policyUnsupported);
      }
      operation = _network(
        source,
        owned,
        maxBytes,
      ).then((reply) => reply.bytes!);
    } else {
      throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
    }
    // Managed policy promises per-hop/read deadlines, never a total call cap.
    return await (managed
        ? operation
        : operation.timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              owned.cancel();
              throw subtitleFailure(
                source is YlNetworkSource
                    ? YlFailureCodes.networkFailed
                    : YlFailureCodes.sourceInvalid,
              );
            },
          ));
  } catch (error) {
    token.check();
    if (error is YlPlayerException) rethrow;
    throw subtitleFailure(
      source is YlNetworkSource
          ? YlFailureCodes.networkFailed
          : YlFailureCodes.sourceMissing,
    );
  } finally {
    remove();
    owned.cancel();
  }
}

const _redirects = {301, 302, 303, 307, 308};
const _retryStatuses = {408, 429, 500, 502, 503, 504};

// A range scan shares these counters and the final credential scope across all
// windows; an external subtitle uses a fresh ledger for its single resource.
final class _NetworkLedger {
  _NetworkLedger(this.uri, {this.rangeScan = false});
  Uri uri;
  final bool rangeScan;
  bool stripped = false;
  int redirects = 0, retries = 0, attempts = 0, bodyBytes = 0;
  void attempt() {
    if (rangeScan && ++attempts > 4096) {
      throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
    }
  }

  void progress(int count) {
    if (!rangeScan) return;
    if (count > 64 * 1024 * 1024 - bodyBytes) {
      throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
    }
    bodyBytes += count;
  }
}

Future<_Reply> _network(
  YlNetworkSource source,
  SubtitleCancellation token,
  int maxBytes, {
  _NetworkLedger? shared,
  _RangeRequest? range,
}) async {
  final policy = source.networkPolicy;
  final managed = policy.kind == YlNetworkPolicyKind.managed;
  final ledger = shared ?? _NetworkLedger(source.uri);
  while (true) {
    token.check();
    ledger.attempt();
    _Reply reply;
    try {
      reply =
          await _Attempt(
            token,
            maxBytes,
            range: range,
            progress: ledger.progress,
          ).get(
            ledger.uri,
            source.request,
            ledger.stripped,
            managed ? policy.connectTimeout : null,
            managed ? policy.readTimeout : null,
          );
    } catch (error) {
      token.check();
      if (!managed ||
          !_transient(error) ||
          ledger.retries >= policy.maxRetries!) {
        rethrow;
      }
      await _wait(
        subtitleRetryDelay(policy, ++ledger.retries, null, DateTime.now())!,
        token,
      );
      continue;
    }
    token.check();
    if (_redirects.contains(reply.status)) {
      final location = reply.location;
      if (location == null ||
          location.length > 8192 ||
          ledger.redirects >= (managed ? policy.maxRedirects! : 5)) {
        throw subtitleFailure(YlFailureCodes.networkFailed);
      }
      // Strong validators are scoped to one resource URI. Do not combine a
      // later redirected resource with already cached bytes, even with same tag.
      if (range?.expectedTag != null) {
        throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
      }
      final next = ledger.uri.resolve(location);
      validateYlExternalSubtitles([
        YlExternalSubtitle(
          id: 'redirect',
          format: YlSubtitleFormat.srt,
          source: YlNetworkSource(next),
        ),
      ]);
      if (ledger.uri.scheme == 'https' && next.scheme != 'https') {
        throw subtitleFailure(YlFailureCodes.networkFailed);
      }
      ledger.stripped |=
          next.scheme != ledger.uri.scheme ||
          next.host != ledger.uri.host ||
          next.port != ledger.uri.port;
      ledger.redirects++;
      ledger.uri = next;
      continue;
    }
    if (reply.bytes != null) return reply;
    if (!managed ||
        !_retryStatuses.contains(reply.status) ||
        ledger.retries >= policy.maxRetries!) {
      throw subtitleFailure(YlFailureCodes.networkFailed);
    }
    final delay = subtitleRetryDelay(
      policy,
      ledger.retries + 1,
      reply.retryAfter,
      DateTime.now(),
    );
    if (delay == null) throw subtitleFailure(YlFailureCodes.networkFailed);
    ledger.retries++;
    await _wait(delay, token);
  }
}

// Conservative structured exception classification. TLS/validation/protocol
// errors are never retried. Dart 3.12 wraps premature closes in HttpException;
// recognize only its exact local SDK messages, never arbitrary server text.
bool _transient(Object error) =>
    error is TimeoutException ||
    error is SocketException ||
    (error is HttpException &&
        const {
          'Connection closed while receiving data',
          'Connection closed before full header was received',
          'Connection closed before full body was received',
          'Connection closed before response was received',
          'Connection closed before data was received',
          'Socket closed before request was sent',
        }.contains(error.message));

/// Null means a valid Retry-After exceeded the permitted wait. Wall time is an
/// explicit input; actual delays are scheduled with monotonic Dart timers.
Duration? subtitleRetryDelay(
  YlNetworkPolicy policy,
  int retryIndex,
  String? retryAfter,
  DateTime now,
) {
  final maximum = policy.maxRetryDelay!;
  final value = retryAfter?.trim();
  if (value != null && value.isNotEmpty) {
    if (RegExp(r'^\d+$').hasMatch(value)) {
      final digits = value.replaceFirst(RegExp(r'^0+'), '');
      // maxRetryDelay is signed32 milliseconds. Avoid integer overflow even
      // for an arbitrarily long syntactically valid seconds field.
      if (digits.length > 7) return null;
      final seconds = digits.isEmpty ? 0 : int.parse(digits);
      final delay = Duration(seconds: seconds);
      return delay <= maximum ? delay : null;
    }
    final date = _retryDate(value, now.toUtc());
    if (date != null) {
      final difference = date.difference(now.toUtc());
      final delay = difference.isNegative ? Duration.zero : difference;
      return delay <= maximum ? delay : null;
    }
  }
  final base = policy.baseRetryDelay!.inMilliseconds;
  final cap = maximum.inMilliseconds;
  if (base == 0 || cap == 0) return Duration.zero;
  if (retryIndex > 31 || base >= cap) return maximum;
  final calculated = base * (1 << (retryIndex - 1));
  return Duration(milliseconds: calculated > cap ? cap : calculated);
}

// RFC 9110 section 5.6.7: accept all three HTTP date forms, reject invalid
// calendar fields instead of DateTime's normalization. Dart 3.12 HttpDate.parse
// normalizes invalid days and treats RFC850 year26 as AD26, so don't use it here.
DateTime? _retryDate(String value, DateTime now) {
  const dayName = r'(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)';
  const monthName = r'(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)';
  const clock = r'(\d{2}):(\d{2}):(\d{2})';
  var match = RegExp(
    '^$dayName, (\\d{2}) $monthName (\\d{4}) $clock GMT\$',
  ).firstMatch(value);
  var obsolete = false;
  late int day, month, year, hour, minute, second;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  if (match == null) {
    match = RegExp(
      '^(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), (\\d{2})-$monthName-(\\d{2}) $clock GMT\$',
    ).firstMatch(value);
    obsolete = match != null;
  }
  if (match != null) {
    day = int.parse(match[1]!);
    month = months.indexOf(match[2]!) + 1;
    year = int.parse(match[3]!);
    hour = int.parse(match[4]!);
    minute = int.parse(match[5]!);
    second = int.parse(match[6]!);
    if (obsolete) year += ((now.year + 50) ~/ 100) * 100;
  } else {
    match = RegExp(
      '^$dayName $monthName ([ \\d]\\d) $clock (\\d{4})\$',
    ).firstMatch(value);
    if (match == null) return null;
    month = months.indexOf(match[1]!) + 1;
    day = int.parse(match[2]!.trim());
    hour = int.parse(match[3]!);
    minute = int.parse(match[4]!);
    second = int.parse(match[5]!);
    year = int.parse(match[6]!);
  }
  if (hour > 23 || minute > 59 || second > 60 || day < 1 || day > 31) {
    return null;
  }
  // Leap-second 60 denotes the following instant; validate the other fields
  // against second59 before adding that one second.
  DateTime date(int y) =>
      DateTime.utc(y, month, day, hour, minute, second == 60 ? 59 : second);
  var parsed = date(year);
  if (obsolete &&
      parsed.isAfter(
        DateTime.utc(
          now.year + 50,
          now.month,
          now.day,
          now.hour,
          now.minute,
          now.second,
          now.millisecond,
          now.microsecond,
        ),
      )) {
    year -= 100;
    parsed = date(year);
  }
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    return null;
  }
  return second == 60 ? parsed.add(const Duration(seconds: 1)) : parsed;
}

Future<void> _wait(Duration delay, SubtitleCancellation token) async {
  token.check();
  final done = Completer<void>();
  final timer = Timer(delay, done.complete);
  final remove = token.listen(() {
    timer.cancel();
    if (!done.isCompleted) {
      done.completeError(subtitleFailure(YlFailureCodes.loadCancelled));
    }
  });
  try {
    await done.future;
    token.check();
  } finally {
    timer.cancel();
    remove();
  }
}

final class _Reply {
  const _Reply(this.status, {this.bytes, this.location, this.retryAfter});
  final int status;
  final List<int>? bytes;
  final String? location;
  final String? retryAfter;
}

/// One hop owns all handles. A new client per hop prevents pooled-connection
/// replay from consuming retries outside our ledger. Every partial buffer dies
/// with its attempt; timed-out callbacks cannot touch the next attempt.
final class _Attempt {
  _Attempt(
    SubtitleCancellation token,
    this.maxBytes, {
    this.range,
    this.progress,
  }) {
    _remove = token.listen(
      () => _fail(subtitleFailure(YlFailureCodes.loadCancelled)),
    );
  }
  final int maxBytes;
  final _RangeRequest? range;
  final void Function(int count)? progress;
  final _result = Completer<_Reply>();
  final _connecting = <void Function()>{};
  void Function() _remove = () {};
  HttpClient? _client;
  HttpClientRequest? _request;
  StreamSubscription<List<int>>? _body;
  Timer? _deadline;
  Object? _transportError;
  bool get active => !_result.isCompleted;

  void _arm(Duration? duration) {
    _deadline?.cancel();
    if (duration != null) {
      _deadline = Timer(
        duration,
        () => _fail(TimeoutException('Subtitle transport deadline', duration)),
      );
    }
  }

  void _cleanup() {
    _deadline?.cancel();
    _remove();
    unawaited(_body?.cancel().catchError((Object _) {}));
    _request?.abort();
    for (final cancel in _connecting.toList()) {
      cancel();
    }
    _connecting.clear();
    _client?.close(force: true);
  }

  void _fail(Object error) {
    if (!active) return;
    _result.completeError(
      error is HttpException ? _transportError ?? error : error,
    );
    _cleanup();
  }

  void _complete(_Reply reply) {
    if (!active) return;
    _result.complete(reply);
    _cleanup();
  }

  Future<_Reply> file(String path) {
    if (active) _collect(File(path).openRead(), null);
    return _result.future.whenComplete(_cleanup);
  }

  Future<_Reply> get(
    Uri uri,
    YlHttpRequest metadata,
    bool stripped,
    Duration? connectTimeout,
    Duration? readTimeout,
  ) {
    if (active) {
      _arm(connectTimeout);
      unawaited(_get(uri, metadata, stripped, readTimeout).catchError(_fail));
    }
    return _result.future.whenComplete(_cleanup);
  }

  Future<void> _get(
    Uri uri,
    YlHttpRequest metadata,
    bool stripped,
    Duration? readTimeout,
  ) async {
    final http = HttpClient()..autoUncompress = false;
    _client = http;
    http.findProxy = (_) => 'DIRECT';
    http.connectionFactory = (uri, _, _) async {
      Socket observe(Socket socket) => observeSubtitleSocket(socket, (error) {
        if (active) _transportError ??= error;
      });
      if (uri.scheme != 'https') {
        final task = await Socket.startConnect(uri.host, uri.port);
        return ConnectionTask.fromSocket(
          task.socket.then(observe),
          task.cancel,
        );
      }
      final task = await RawSocket.startConnect(uri.host, uri.port);
      RawSocket? raw;
      var closed = false;
      void close() {
        closed = true;
        task.cancel();
        raw?.close();
      }

      _connecting.add(close);
      if (!active) close();
      final socket = task.socket.then<Socket>((value) async {
        raw = value;
        if (closed || !active) {
          value.close();
          throw const SocketException('Cancelled');
        }
        try {
          final secure = await RawSecureSocket.secure(value, host: uri.host);
          if (closed || !active) {
            secure.close();
            throw const SocketException('Cancelled');
          }
          return observe(YlLicenseSecureSocket(secure));
        } catch (_) {
          value.close();
          rethrow;
        } finally {
          _connecting.remove(close);
        }
      });
      return ConnectionTask.fromSocket(socket, close);
    };
    final request = await http.getUrl(uri);
    _request = request;
    if (!active) {
      request.abort();
      return;
    }
    request.followRedirects = false;
    request.maxRedirects = 0;
    request.persistentConnection = false;
    metadata.headers.forEach(request.headers.set);
    if (!stripped) metadata.credentials.forEach(request.headers.set);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (range case final r?) {
      request.headers.set('range', 'bytes=${r.start}-${r.end}');
      if (r.expectedTag != null) {
        request.headers.set('if-match', r.expectedTag!);
      }
    }
    final response = await request.close();
    if (!active) return;
    _deadline?.cancel();
    if (range != null && response.statusCode == 200) {
      throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
    }
    if (response.statusCode != (range == null ? 200 : 206)) {
      final retryAfter = response.headers['retry-after'];
      _complete(
        _Reply(
          response.statusCode,
          location: _redirects.contains(response.statusCode)
              ? response.headers.value('location')
              : null,
          retryAfter: retryAfter?.length == 1 ? retryAfter!.single : null,
        ),
      );
      return;
    }
    final encoding = response.headers.value('content-encoding');
    if (encoding != null && encoding.toLowerCase() != 'identity') {
      throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
    }
    range?.accept(response);
    if (response.contentLength > maxBytes) {
      throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
    }
    _collect(response, readTimeout);
  }

  void _collect(Stream<List<int>> stream, Duration? readTimeout) {
    final bytes = BytesBuilder(copy: false);
    _arm(readTimeout);
    _body = stream.listen(
      (chunk) {
        if (!active || chunk.isEmpty) return;
        try {
          progress?.call(chunk.length);
        } catch (error) {
          _fail(error);
          return;
        }
        if (chunk.length > maxBytes - bytes.length) {
          _fail(subtitleFailure(YlFailureCodes.subtitleTooLarge));
          return;
        }
        bytes.add(chunk);
        _arm(readTimeout);
      },
      onError: _fail,
      onDone: () {
        if (range != null && bytes.length != range!.receivedLength) {
          _fail(subtitleFailure(YlFailureCodes.networkFailed));
          return;
        }
        _complete(_Reply(range == null ? 200 : 206, bytes: bytes.takeBytes()));
      },
    );
  }
}
