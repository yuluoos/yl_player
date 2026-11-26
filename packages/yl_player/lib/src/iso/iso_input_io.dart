import 'dart:async';
import 'dart:io';

import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'iso_image.dart';
import 'iso_input.dart';
import 'iso_server.dart';

IsoInput create(YlMediaSource source) => _Input(
  IsoServer(switch (source) {
    YlFileSource() => IsoImage.file(source.path),
    YlNetworkSource() => IsoImage.network(
      source.uri,
      source.request.headers,
      source.request.credentials,
    ),
    _ => throw isoError(
      YlFailureCodes.policyUnsupported,
      'Unsupported image location.',
    ),
  }),
);

final class _Input implements IsoInput {
  _Input(this.server);
  final IsoServer server;
  @override
  Future<YlNetworkSource> open(int? playlist) async {
    try {
      await server.open(playlist: playlist);
      return YlNetworkSource(
        server.uri,
        format: YlMediaFormat.hls,
        intent: YlStreamIntent.onDemand,
      );
    } on IsoRangeException {
      throw isoError(
        YlFailureCodes.networkIsoRangeUnavailable,
        'This server must serve consistent HTTP byte ranges. Download the ISO and open it locally.',
      );
    } on FileSystemException {
      throw isoError(
        YlFailureCodes.sourceMissing,
        'The disc image could not be read.',
      );
    } on TimeoutException {
      throw isoError(
        YlFailureCodes.networkFailed,
        'The image server timed out.',
      );
    } on IOException {
      throw isoError(
        YlFailureCodes.networkFailed,
        'The disc image request failed.',
      );
    } on FormatException {
      throw isoError(
        YlFailureCodes.containerUnsupported,
        'Expected an unencrypted UDF Blu-ray image with a supported playlist.',
      );
    } on RangeError {
      throw isoError(
        YlFailureCodes.containerUnsupported,
        'Invalid Blu-ray navigation data.',
      );
    }
  }

  @override
  Future<void> close() => server.close();
}
