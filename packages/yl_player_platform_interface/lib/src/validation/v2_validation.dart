import '../options/load_options.dart';
import '../options/player_options.dart';
import '../options/policies.dart';
import '../options/video_constraints.dart';
import '../source/http_request.dart';
import '../source/media_source.dart';

const _maxPolicyInt = 0x7fffffff;
const _maxTimelineInt = 0x7fffffffffffffff;
const _maxPolicyDuration = Duration(milliseconds: _maxPolicyInt);
final _headerToken = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
final _unsafeHeaderValue = RegExp(r'[\x00-\x08\x0a-\x1f\x7f]');
final _unsafePathCharacter = RegExp(r'[\x00-\x1f\x7f]');
final _windowsDrive = RegExp(r'^[A-Za-z]:[\\/]');
final _credentialName = RegExp(r'auth|cookie|token|key|secret|credential');
const _reservedHeaders = {
  'host',
  'content-length',
  'connection',
  'transfer-encoding',
  'range',
};

/// Validates a source before any platform call. Errors never include identities
/// or request metadata, including in ArgumentError.invalidValue.
void validateYlSource(YlMediaSource source) {
  switch (source) {
    case YlFileSource():
      _validatePath(source.path);
    case YlNetworkSource():
      _validateUri(source.uri, network: true);
      _validateRequest(source.request);
      _validateNetworkPolicy(source.networkPolicy);
    case YlAndroidContentSource():
      _validateUri(source.uri, network: false);
  }
}

void _validateUri(Uri uri, {required bool network}) {
  // Custom Uri implementations and lazy component parsing must not leak the
  // original input through a FormatException or ArgumentError.value.
  var valid = false;
  try {
    valid =
        (network
            ? uri.scheme == 'http' || uri.scheme == 'https'
            : uri.scheme == 'content') &&
        uri.hasAuthority &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.authority.contains('@') &&
        !_unsafePathCharacter.hasMatch(uri.host) &&
        !uri.host.contains(' ') &&
        (!network || (uri.port > 0 && uri.port <= 65535));
  } on FormatException {
    valid = false;
  } on ArgumentError {
    valid = false;
  }
  if (!valid) throw ArgumentError('Source URI is invalid.');
}

void _validatePath(String path) {
  var absolute = path.startsWith('/') || _windowsDrive.hasMatch(path);
  if (path.startsWith(r'\\')) {
    final components = path.substring(2).split(RegExp(r'[\\/]'));
    absolute =
        components.length >= 2 &&
        components[0].isNotEmpty &&
        components[1].isNotEmpty &&
        components[0] != '.' &&
        components[0] != '?' &&
        components[1] != '.' &&
        components[1] != '..';
  }
  if (path.isEmpty || !absolute || _unsafePathCharacter.hasMatch(path)) {
    throw ArgumentError('Source path must be a valid absolute path.');
  }
}

void _validateRequest(YlHttpRequest request) {
  final seen = <String>{};
  void validateHeaders(
    Map<String, String> headers, {
    required bool credentials,
  }) {
    for (final entry in headers.entries) {
      final name = entry.key.toLowerCase();
      if (!_headerToken.hasMatch(entry.key) ||
          _unsafeHeaderValue.hasMatch(entry.value) ||
          _reservedHeaders.contains(name) ||
          !seen.add(name) ||
          (!credentials && _credentialName.hasMatch(name))) {
        throw ArgumentError('HTTP request metadata is invalid.');
      }
    }
  }

  validateHeaders(request.headers, credentials: false);
  validateHeaders(request.credentials, credentials: true);
}

void _validateNetworkPolicy(YlNetworkPolicy policy) {
  if (policy.kind == YlNetworkPolicyKind.platformDefault) return;
  _policyDuration(policy.connectTimeout!, positive: true);
  _policyDuration(policy.readTimeout!, positive: true);
  _policyInt(policy.maxRetries!, positive: false);
  _policyDuration(policy.baseRetryDelay!);
  _policyDuration(policy.maxRetryDelay!);
  _policyInt(policy.maxRedirects!, positive: false);
  if (policy.baseRetryDelay! > policy.maxRetryDelay!) {
    throw ArgumentError('Retry delay limits must be ordered.');
  }
}

/// Validates creation options before a platform player is allocated.
void validateYlPlayerOptions(YlPlayerOptions options) {
  _policyDuration(options.positionUpdateInterval, positive: true);
}

/// Validates load choices before issuing a platform load command.
void validateYlLoadOptions(YlLoadOptions options) {
  final position = options.startPosition;
  if (position != null) validateYlSeekPosition(position);
  validateYlVideoConstraints(options.videoConstraints);
  final strategy = options.bufferStrategy;
  if (strategy.kind == YlBufferStrategyKind.bounded) {
    _policyDuration(strategy.minDuration!);
    _policyDuration(strategy.maxDuration!);
    _policyInt(strategy.maxManagedBytes!, positive: true);
    if (strategy.minDuration! > strategy.maxDuration!) {
      throw ArgumentError('Buffer duration limits must be ordered.');
    }
  }
}

/// Used for both initial load and runtime adaptive-video constraint commands.
void validateYlVideoConstraints(YlVideoConstraints constraints) {
  for (final limit in [
    constraints.maxWidth,
    constraints.maxHeight,
    constraints.maxBitrate,
  ]) {
    if (limit != null) _policyInt(limit, positive: true);
  }
}

void validateYlVolume(double volume) {
  if (!volume.isFinite || volume < 0 || volume > 1) {
    throw ArgumentError('Volume must be finite and between 0 and 1.');
  }
}

void validateYlPlaybackSpeed(double speed) {
  if (!speed.isFinite || speed < 0.25 || speed > 4) {
    throw ArgumentError(
      'Playback speed must be finite and between 0.25 and 4.',
    );
  }
}

/// Media time uses nonnegative signed64 transport milliseconds, never the
/// signed32 policy limit. Dart Duration stores microseconds, so all nonnegative
/// native Dart durations already fit the transport millisecond upper bound.
void validateYlSeekPosition(Duration position) {
  if (position.isNegative || position.inMilliseconds > _maxTimelineInt) {
    throw ArgumentError(
      'Seek position must fit nonnegative timeline milliseconds.',
    );
  }
}

void validateYlTrackId(String trackId) {
  if (trackId.isEmpty) throw ArgumentError('Track ID must not be empty.');
}

void _policyDuration(Duration duration, {bool positive = false}) {
  if (duration.inMicroseconds % Duration.microsecondsPerMillisecond != 0 ||
      duration.isNegative ||
      duration > _maxPolicyDuration ||
      (positive && duration.inMilliseconds < 1)) {
    throw ArgumentError(
      'Policy duration is outside the native millisecond range.',
    );
  }
}

void _policyInt(int value, {required bool positive}) {
  if (value < (positive ? 1 : 0) || value > _maxPolicyInt) {
    throw ArgumentError('Policy value is outside the native integer range.');
  }
}
