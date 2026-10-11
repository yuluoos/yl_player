import 'dart:async';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'subtitle_resource_stub.dart'
    if (dart.library.io) 'subtitle_resource_io.dart'
    as transport;

YlPlayerException subtitleFailure(String code) => YlPlayerException(
  YlFailure(
    code: code,
    category: switch (code) {
      YlFailureCodes.loadCancelled => YlFailureCategory.cancelled,
      YlFailureCodes.subtitleUnsupported ||
      YlFailureCodes.policyUnsupported => YlFailureCategory.unsupported,
      YlFailureCodes.subtitleTooLarge => YlFailureCategory.resource,
      YlFailureCodes.networkFailed => YlFailureCategory.network,
      _ => YlFailureCategory.source,
    },
    scope: YlFailureScope.command,
    retryable: false,
    message: 'Subtitle operation failed.',
    diagnosticId: 'text-subtitle',
  ),
);

final class SubtitleCancellation {
  final _done = Completer<void>();
  bool get isCancelled => _done.isCompleted;
  Future<void> get cancelled => _done.future;
  void cancel() {
    if (!isCancelled) _done.complete();
  }

  void check() {
    if (isCancelled) throw subtitleFailure(YlFailureCodes.loadCancelled);
  }
}

Future<List<int>> readSubtitleResource(
  YlMediaSource source,
  SubtitleCancellation token,
  int maxBytes,
) => transport.read(source, token, maxBytes);
