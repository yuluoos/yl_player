import '../model/value_helpers.dart';

enum YlDecoderPolicy { systemDefault, hardwarePreferred, hardwareRequired }

enum YlAudioPolicy { appManaged, pluginManagedMediaPlayback }

enum YlNetworkPolicyKind { platformDefault, managed }

enum YlBufferStrategyKind { automatic, lowLatency, smoothPlayback, bounded }

/// Source-specific transport guarantees. Unsupported requirements must fail.
/// Policy durations must be whole signed32 milliseconds; timeouts are positive,
/// retry delays are nonnegative, and counts are nonnegative signed32 integers.
///
/// Both kinds enforce credential origin protection. [platformDefault] delegates
/// scheduling, timeout and retry behavior without promising exact values.
///
/// Managed connect time is the per-hop deadline through response headers,
/// including DNS, connection, TLS and server wait. Read time measures body
/// inactivity after headers and resets only on progress. No total call timeout
/// is promised. Retry only idempotent GET/HEAD on transient transport errors or
/// HTTP 408/429/500/502/503/504, never cancellation, validation or certificate
/// failures. [maxRetries] excludes the initial attempt.
///
/// Retry n (starting at 1) waits min(maxRetryDelay, baseRetryDelay * 2^(n-1)),
/// saturating without jitter. A valid nonnegative Retry-After seconds/date wins
/// if within maxRetryDelay; otherwise do not retry. Malformed Retry-After falls
/// back to the formula. Native implementations inject wall time for date tests
/// and use monotonic time for scheduling. Redirects have a separate counter
/// spanning all attempts for the original resource request. They consume no
/// retries. Stripped credentials remain stripped on retries and HLS children.
final class YlNetworkPolicy {
  const YlNetworkPolicy.platformDefault()
    : kind = YlNetworkPolicyKind.platformDefault,
      connectTimeout = null,
      readTimeout = null,
      maxRetries = null,
      baseRetryDelay = null,
      maxRetryDelay = null,
      maxRedirects = null;

  /// Explicitly requests managed transport. Defaults are 10s to headers, 15s
  /// body inactivity, 3 retries, 500ms base / 8s maximum delay and 5 redirects.
  const YlNetworkPolicy.managed({
    Duration this.connectTimeout = const Duration(seconds: 10),
    Duration this.readTimeout = const Duration(seconds: 15),
    int this.maxRetries = 3,
    Duration this.baseRetryDelay = const Duration(milliseconds: 500),
    Duration this.maxRetryDelay = const Duration(seconds: 8),
    int this.maxRedirects = 5,
  }) : kind = YlNetworkPolicyKind.managed;

  final YlNetworkPolicyKind kind;
  final Duration? connectTimeout;
  final Duration? readTimeout;
  final int? maxRetries;
  final Duration? baseRetryDelay;
  final Duration? maxRetryDelay;
  final int? maxRedirects;

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        kind == other.kind &&
        connectTimeout == other.connectTimeout &&
        readTimeout == other.readTimeout &&
        maxRetries == other.maxRetries &&
        baseRetryDelay == other.baseRetryDelay &&
        maxRetryDelay == other.maxRetryDelay &&
        maxRedirects == other.maxRedirects,
  );

  @override
  int get hashCode => Object.hash(
    kind,
    connectTimeout,
    readTimeout,
    maxRetries,
    baseRetryDelay,
    maxRetryDelay,
    maxRedirects,
  );

  @override
  String toString() =>
      'YlNetworkPolicy(kind: ${kind.name}, '
      'connectTimeout: $connectTimeout, readTimeout: $readTimeout, '
      'maxRetries: $maxRetries, baseRetryDelay: $baseRetryDelay, '
      'maxRetryDelay: $maxRetryDelay, maxRedirects: $maxRedirects)';
}

/// Built-in strategies are optimization goals. [bounded] requires exact
/// managed-media duration and byte admission limits, not a process RSS bound.
/// Platforms unable to enforce the required budget must reject it. Durations
/// are whole nonnegative signed32 milliseconds; bytes are positive signed32.
final class YlBufferStrategy {
  const YlBufferStrategy.automatic()
    : kind = YlBufferStrategyKind.automatic,
      minDuration = null,
      maxDuration = null,
      maxManagedBytes = null;

  const YlBufferStrategy.lowLatency()
    : kind = YlBufferStrategyKind.lowLatency,
      minDuration = null,
      maxDuration = null,
      maxManagedBytes = null;

  const YlBufferStrategy.smoothPlayback()
    : kind = YlBufferStrategyKind.smoothPlayback,
      minDuration = null,
      maxDuration = null,
      maxManagedBytes = null;

  const YlBufferStrategy.bounded({
    required Duration this.minDuration,
    required Duration this.maxDuration,
    required int this.maxManagedBytes,
  }) : kind = YlBufferStrategyKind.bounded;

  final YlBufferStrategyKind kind;
  final Duration? minDuration;
  final Duration? maxDuration;
  final int? maxManagedBytes;

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        kind == other.kind &&
        minDuration == other.minDuration &&
        maxDuration == other.maxDuration &&
        maxManagedBytes == other.maxManagedBytes,
  );

  @override
  int get hashCode =>
      Object.hash(kind, minDuration, maxDuration, maxManagedBytes);

  @override
  String toString() =>
      'YlBufferStrategy(kind: ${kind.name}, '
      'minDuration: $minDuration, maxDuration: $maxDuration, '
      'maxManagedBytes: $maxManagedBytes)';
}
