import 'dart:async';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

/// Bounded acknowledgement history. Each full snapshot identifies its native
/// commit, so a later mode or metrics tick cannot erase a waiting reply's proof.
final class LiveModeBarrier {
  LiveModeBarrier({this.deadline = const Duration(seconds: 5)});
  final Duration deadline;
  final _pending = <int, LiveModeRequest>{};
  int _counter = 0;
  int get pendingCount => _pending.length;

  LiveModeRequest begin(String session, YlLivePlaybackMode mode, int revision) {
    if (_pending.length >= 32 || _counter == 0x7fffffffffffffff) {
      throw _error(
        YlFailureCodes.resourceExhausted,
        YlFailureCategory.resource,
      );
    }
    final request = LiveModeRequest(++_counter, session, mode, revision);
    _pending[request.id] = request;
    return request;
  }

  void snapshot(
    String session,
    int? id,
    int revision,
    YlLivePlaybackMode mode,
  ) {
    final request = _pending[id];
    if (request == null || request.session != session) return;
    if (mode != request.mode || revision <= request.initialRevision) {
      fail(request.id, _mismatch);
      return;
    }
    // The first accepted full snapshot for this ID is the commit boundary.
    request.snapshotRevision ??= revision;
    _pair(request);
  }

  void reply(int id, String session, int echoedId, int revision) {
    final request = _pending[id];
    if (request == null) return;
    if (session != request.session ||
        echoedId != id ||
        revision <= request.initialRevision) {
      fail(id, _mismatch);
      return;
    }
    request.replyRevision = revision;
    _pair(request);
  }

  void _pair(LiveModeRequest request) {
    final snapshot = request.snapshotRevision, reply = request.replyRevision;
    if (snapshot != null && reply != null) {
      if (snapshot != reply) {
        fail(request.id, _mismatch);
        return;
      }
      _pending.remove(request.id);
      request.timer?.cancel();
      request.completion.complete();
    } else {
      request.timer ??= Timer(deadline, () => fail(request.id, _mismatch));
    }
  }

  void fail(int id, Object error) {
    final request = _pending.remove(id);
    if (request == null) return;
    request.timer?.cancel();
    request.completion.completeError(error);
  }

  void cancelAll([Object? error]) {
    final failure =
        error ??
        _error(YlFailureCodes.sessionStale, YlFailureCategory.cancelled);
    for (final id in _pending.keys.toList()) {
      fail(id, failure);
    }
  }

  YlPlayerException get _mismatch =>
      _error(YlFailureCodes.protocolMismatch, YlFailureCategory.protocol);
  static YlPlayerException _error(String code, YlFailureCategory category) =>
      YlPlayerException(
        YlFailure(
          code: code,
          category: category,
          scope: YlFailureScope.command,
          message: 'Live playback command could not be acknowledged.',
          retryable: false,
          diagnosticId: 'live-mode-barrier',
        ),
      );
}

final class LiveModeRequest {
  LiveModeRequest(this.id, this.session, this.mode, this.initialRevision);
  final int id;
  final String session;
  final YlLivePlaybackMode mode;
  final int initialRevision;
  final completion = Completer<void>();
  Future<void> get future => completion.future;
  int? snapshotRevision;
  int? replyRevision;
  Timer? timer;
}
