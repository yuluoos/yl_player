/// Public state observation only; this does not observe rendered audio or video.
final class SeekProgressWindow {
  SeekProgressWindow({
    required this.session,
    required this.startedUs,
    required this.targetUs,
    this.toleranceUs = 250000,
    this.windowUs = 1000000,
    this.maximumGapUs = 500000,
  });
  final String session;
  final int startedUs, targetUs, toleranceUs, windowUs, maximumGapUs;
  int? firstNearUs, stableUs;
  bool cancelled = false;
  int? _lastUs, _lastPositionUs, _windowStartUs, _windowPositionUs;
  void observe({
    required String? sessionId,
    required int nowUs,
    required int positionUs,
    required bool playing,
    required bool buffering,
  }) {
    if (nowUs < startedUs ||
        (_lastUs != null && nowUs <= _lastUs!) ||
        positionUs < 0) {
      throw const FormatException('Invalid seek observation clock');
    }
    final gap = _lastUs == null ? 0 : nowUs - _lastUs!;
    final backwards = _lastPositionUs != null && positionUs < _lastPositionUs!;
    _lastPositionUs = positionUs;
    _lastUs = nowUs;
    if (sessionId != session) cancelled = true;
    if (cancelled || stableUs != null) return;
    if (firstNearUs == null) {
      if ((positionUs - targetUs).abs() > toleranceUs) return;
      firstNearUs = nowUs;
    }
    if (!playing || buffering || backwards || gap > maximumGapUs) {
      _windowStartUs = null;
      _windowPositionUs = null;
      if (!playing || buffering) return;
    }
    if (_windowStartUs != null) {
      final elapsed = nowUs - _windowStartUs!;
      final advance = positionUs - _windowPositionUs!;
      // Public cadence can hold a position between updates. A full window must
      // still progress at the frozen 0.5–1.5x bounds, and never move backward.
      if (advance < 0 ||
          (elapsed >= windowUs &&
              (advance < elapsed ~/ 2 || advance > elapsed * 3 ~/ 2))) {
        _windowStartUs = null;
        _windowPositionUs = null;
      } else if (elapsed >= windowUs) {
        stableUs = nowUs;
        return;
      }
    }
    _windowStartUs ??= nowUs;
    _windowPositionUs ??= positionUs;
  }
}
