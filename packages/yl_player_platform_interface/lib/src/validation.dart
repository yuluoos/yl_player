import 'configuration.dart';

const int _maxNativeInt = 0x7fffffff;
const int _maxNativeCount = 20;

/// Validates configuration before a native player is created.
void validateYlPlayerConfiguration(YlPlayerConfiguration configuration) {
  final network = configuration.networkPolicy;
  _positiveNativeDuration(network.connectTimeout, 'connectTimeout');
  _positiveNativeDuration(network.readTimeout, 'readTimeout');
  _nativeCount(network.maxRetries, 'maxRetries');
  _nonnegativeNativeDuration(network.baseRetryDelay, 'baseRetryDelay');
  _nonnegativeNativeDuration(network.maxRetryDelay, 'maxRetryDelay');
  if (network.maxRetryDelay < network.baseRetryDelay) {
    throw ArgumentError.value(
      network.maxRetryDelay,
      'maxRetryDelay',
      'must not be less than baseRetryDelay',
    );
  }
  _nativeCount(network.maxRedirects, 'maxRedirects');

  _positiveNativeDuration(
    configuration.positionEventInterval,
    'positionEventInterval',
  );
  final minBufferDuration = configuration.minBufferDuration;
  if (minBufferDuration != null) {
    _nonnegativeNativeDuration(minBufferDuration, 'minBufferDuration');
  }
  final maxBufferDuration = configuration.maxBufferDuration;
  if (maxBufferDuration != null) {
    _nonnegativeNativeDuration(maxBufferDuration, 'maxBufferDuration');
  }
  if (minBufferDuration != null &&
      maxBufferDuration != null &&
      minBufferDuration > maxBufferDuration) {
    throw ArgumentError.value(
      maxBufferDuration,
      'maxBufferDuration',
      'must not be less than minBufferDuration',
    );
  }
  _optionalPositiveNativeInt(configuration.maxBufferBytes, 'maxBufferBytes');
}

/// Validates a requested seek position.
void validateYlSeekPosition(Duration position) {
  if (position.isNegative) {
    throw ArgumentError.value(position, 'position', 'must not be negative');
  }
}

/// Validates a requested playback speed.
void validateYlPlaybackSpeed(double speed) {
  if (!speed.isFinite || speed < 0.25 || speed > 4.0) {
    throw ArgumentError.value(
      speed,
      'speed',
      'must be finite and between 0.25 and 4.0',
    );
  }
}

/// Validates a requested output volume.
void validateYlVolume(double volume) {
  if (!volume.isFinite || volume < 0.0 || volume > 1.0) {
    throw ArgumentError.value(
      volume,
      'volume',
      'must be finite and between 0.0 and 1.0',
    );
  }
}

/// Validates adaptive-track limits before they cross a platform channel.
void validateYlQualityConstraint(YlQualityConstraint constraint) {
  _optionalPositiveNativeInt(constraint.maxWidth, 'maxWidth');
  _optionalPositiveNativeInt(constraint.maxHeight, 'maxHeight');
  _optionalPositiveNativeInt(constraint.maxBitrate, 'maxBitrate');
}

void _positiveNativeDuration(Duration value, String name) {
  final milliseconds = value.inMilliseconds;
  if (milliseconds <= 0 || milliseconds > _maxNativeInt) {
    throw ArgumentError.value(
      value,
      name,
      'must be between 1 and $_maxNativeInt milliseconds',
    );
  }
}

void _nonnegativeNativeDuration(Duration value, String name) {
  final milliseconds = value.inMilliseconds;
  if (milliseconds < 0 || milliseconds > _maxNativeInt) {
    throw ArgumentError.value(
      value,
      name,
      'must be between 0 and $_maxNativeInt milliseconds',
    );
  }
}

void _nativeCount(int value, String name) {
  if (value < 0 || value > _maxNativeCount) {
    throw ArgumentError.value(
      value,
      name,
      'must be between 0 and $_maxNativeCount',
    );
  }
}

void _optionalPositiveNativeInt(int? value, String name) {
  if (value != null && (value <= 0 || value > _maxNativeInt)) {
    throw ArgumentError.value(
      value,
      name,
      'must be between 1 and $_maxNativeInt',
    );
  }
}
