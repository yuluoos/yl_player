/// Selects a built-in buffering policy.
enum YlBufferMode { automatic, lowLatency, balanced, stable, custom }

/// Controls whether a backend may choose a non-hardware video decoder.
enum YlDecoderPolicy {
  @Deprecated(
    'preferHardware currently resolves to hardwareOnly; use hardwareOnly.',
  )
  preferHardware,
  hardwareOnly,
}

/// Immutable network retry and timeout policy.
final class YlNetworkPolicy {
  const YlNetworkPolicy({
    this.connectTimeout = const Duration(seconds: 10),
    this.readTimeout = const Duration(seconds: 15),
    this.maxRetries = 3,
    this.baseRetryDelay = const Duration(milliseconds: 500),
    this.maxRetryDelay = const Duration(seconds: 8),
    this.maxRedirects = 5,
  });

  final Duration connectTimeout;
  final Duration readTimeout;
  final int maxRetries;
  final Duration baseRetryDelay;
  final Duration maxRetryDelay;
  final int maxRedirects;
}

/// Optional adaptive-track limits supplied by the host application.
final class YlQualityConstraint {
  const YlQualityConstraint({this.maxWidth, this.maxHeight, this.maxBitrate});

  final int? maxWidth;
  final int? maxHeight;
  final int? maxBitrate;
}

/// Player-wide configuration captured when a native player is created.
final class YlPlayerConfiguration {
  const YlPlayerConfiguration({
    this.bufferMode = YlBufferMode.automatic,
    this.decoderPolicy = YlDecoderPolicy.hardwareOnly,
    this.networkPolicy = const YlNetworkPolicy(),
    this.minBufferDuration,
    this.maxBufferDuration,
    this.maxBufferBytes,
    this.positionEventInterval = const Duration(milliseconds: 250),
  });

  final YlBufferMode bufferMode;
  final YlDecoderPolicy decoderPolicy;
  final YlNetworkPolicy networkPolicy;
  final Duration? minBufferDuration;
  final Duration? maxBufferDuration;
  final int? maxBufferBytes;
  final Duration positionEventInterval;
}
