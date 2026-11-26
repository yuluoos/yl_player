import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'iso_input_stub.dart'
    if (dart.library.io) 'iso_input_io.dart'
    as platform;

abstract interface class IsoInput {
  Future<YlNetworkSource> open(int? playlist);
  Future<void> close();
}

bool isDiscImage(YlMediaSource source) =>
    source.format == YlMediaFormat.automatic &&
    switch (source) {
      YlFileSource() => source.path.toLowerCase().endsWith('.iso'),
      YlNetworkSource() =>
        {'http', 'https'}.contains(source.uri.scheme) &&
            source.uri.path.toLowerCase().endsWith('.iso'),
      _ => false,
    };

IsoInput createIsoInput(YlMediaSource source, YlLoadOptions options) {
  if (options.airPlay ||
      options.bufferStrategy.kind == YlBufferStrategyKind.bounded ||
      source.intent == YlStreamIntent.live ||
      source.format != YlMediaFormat.automatic ||
      source is YlNetworkSource &&
          (source.drm != null ||
              source.networkPolicy.kind !=
                  YlNetworkPolicyKind.platformDefault ||
              !{'http', 'https'}.contains(source.uri.scheme) ||
              [
                ...source.request.headers.keys,
                ...source.request.credentials.keys,
              ].any(
                (k) =>
                    k.toLowerCase().startsWith('if-') ||
                    {
                      'accept-encoding',
                      'proxy-authorization',
                    }.contains(k.toLowerCase()),
              )) ||
      source is YlAndroidContentSource) {
    throw isoError(
      YlFailureCodes.policyUnsupported,
      'Unsupported Blu-ray image source or playback policy.',
    );
  }
  return platform.create(source);
}

YlPlayerException isoError(String code, String message) => YlPlayerException(
  YlFailure(
    category: switch (code) {
      YlFailureCodes.policyUnsupported => YlFailureCategory.unsupported,
      YlFailureCodes.sourceMissing => YlFailureCategory.source,
      YlFailureCodes.networkFailed ||
      YlFailureCodes.networkIsoRangeUnavailable => YlFailureCategory.network,
      _ => YlFailureCategory.container,
    },
    code: code,
    message: message,
    retryable: false,
    scope: YlFailureScope.command,
    diagnosticId: 'bluray-iso',
  ),
);
