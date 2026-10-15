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
      YlFailureCodes.subtitleTooLarge ||
      YlFailureCodes.subtitleResourceUnavailable => YlFailureCategory.resource,
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
  final _listeners = <void Function()>{};
  bool get isCancelled => _done.isCompleted;
  Future<void> get cancelled => _done.future;
  void cancel() {
    if (isCancelled) return;
    _done.complete();
    final callbacks = _listeners.toList();
    _listeners.clear();
    for (final callback in callbacks) {
      callback();
    }
  }

  /// Each attempt removes its subscription when done, so retry count does not
  /// determine retained callbacks or sockets.
  void Function() listen(void Function() callback) {
    if (isCancelled) {
      callback();
      return () {};
    }
    _listeners.add(callback);
    return () => _listeners.remove(callback);
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
