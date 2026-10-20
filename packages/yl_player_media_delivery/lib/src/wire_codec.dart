import 'package:flutter/services.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

/// Portable StandardMessageCodec boundary. Never exports upstream diagnostic prose.
abstract final class DeliveryCodec {
  static Map<String, Object?> request(
    YlMediaSource source,
    YlLoadOptions options,
  ) {
    validateYlSource(source);
    validateYlLoadOptions(options);
    final network = source is YlNetworkSource ? source : null;
    final policy =
        network?.networkPolicy ?? const YlNetworkPolicy.platformDefault();
    final drm = network?.drm;
    final buffer = options.bufferStrategy;
    final constraints = options.videoConstraints;
    return {
      'source': {
        'kind': switch (source) {
          YlFileSource() => 'file',
          YlAndroidContentSource() => 'content',
          YlNetworkSource() => 'network',
        },
        'uri': switch (source) {
          YlFileSource() => source.path,
          YlAndroidContentSource() => source.uri.toString(),
          YlNetworkSource() => source.uri.toString(),
        },
        'intent': source.intent.name,
        'format': source.format.name,
        'headers': Map<String, String>.of(network?.request.headers ?? {}),
        'credentials': Map<String, String>.of(
          network?.request.credentials ?? {},
        ),
        'networkPolicy': {
          'kind': policy.kind.name,
          'connectTimeoutMs': policy.connectTimeout?.inMilliseconds,
          'readTimeoutMs': policy.readTimeout?.inMilliseconds,
          'maxRetries': policy.maxRetries,
          'baseRetryDelayMs': policy.baseRetryDelay?.inMilliseconds,
          'maxRetryDelayMs': policy.maxRetryDelay?.inMilliseconds,
          'maxRedirects': policy.maxRedirects,
        },
        if (drm != null)
          'drm': {
            'kind': drm is YlFairPlayDrm ? 'fairPlay' : 'widevine',
            'timeoutMs': drm.license.timeout.inMilliseconds,
            if (drm is YlFairPlayDrm) ...{
              'certificate': drm.certificate.bytes,
              'contentId': drm.contentId.bytes,
            },
          },
      },
      'options': {
        'autoplay': options.autoplay,
        'startPositionMs': options.startPosition?.inMilliseconds,
        'bufferStrategy': {
          'kind': buffer.kind.name,
          'minDurationMs': buffer.minDuration?.inMilliseconds,
          'maxDurationMs': buffer.maxDuration?.inMilliseconds,
          'maxManagedBytes': buffer.maxManagedBytes,
        },
        'maxWidth': constraints.maxWidth,
        'maxHeight': constraints.maxHeight,
        'maxBitrate': constraints.maxBitrate,
        'decoderPolicyOverride': options.decoderPolicyOverride?.name,
      },
    };
  }

  static YlPlayerException problem(
    String code, {
    YlFailureCategory category = YlFailureCategory.protocol,
    YlFailureScope scope = YlFailureScope.command,
  }) => YlPlayerException(
    YlFailure(
      category: category,
      code: code,
      message: YlSafeDiagnostics.messageForCode(code),
      retryable: false,
      scope: scope,
      diagnosticId: 'media-delivery',
    ),
  );

  static YlFailure failure(Map value) {
    final rawCode = value['code'];
    final code =
        rawCode is String &&
            RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(rawCode)
        ? rawCode
        : YlFailureCodes.platformFailure;
    final category = switch (value['category']) {
      'protocolFailure' => YlFailureCategory.protocol,
      'internalFailure' => YlFailureCategory.internal,
      final String name =>
        YlFailureCategory.values.where((c) => c.name == name).firstOrNull ??
            YlFailureCategory.platform,
      _ => YlFailureCategory.platform,
    };
    return problem(code, category: category).failure;
  }

  static YlPlayerException exception(Object error) {
    if (error is YlPlayerException) return error;
    if (error is MissingPluginException) {
      return problem(
        YlFailureCodes.policyUnsupported,
        category: YlFailureCategory.unsupported,
      );
    }
    if (error is PlatformException) {
      return YlPlayerException(
        failure({
          'code': error.code,
          if (error.details is Map)
            'category': (error.details as Map)['category'],
        }),
      );
    }
    return problem(
      YlFailureCodes.platformFailure,
      category: YlFailureCategory.platform,
    );
  }
}
