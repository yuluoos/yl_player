import 'package:flutter/foundation.dart';

import 'models.dart';

abstract interface class YlCastProvider {
  String get id;
  ValueListenable<List<YlCastDevice>> get devices;
  ValueListenable<YlCastDiscoveryState> get discovery;
  Future<void> startDiscovery();
  Future<void> stopDiscovery();
  Future<YlCastAssessment> assess(YlCastDevice device, YlCastRequest request);
  Future<YlCastRemoteSession> connect(YlCastDevice device);
  Future<void> dispose();
}

abstract interface class YlCastRemoteSession {
  YlCastDevice get device;
  YlCastCapabilities get capabilities;
  ValueListenable<YlCastPlaybackState> get state;
  Future<void> load(YlCastRequest request);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setMuted(bool muted);

  /// Release control. Stop first if playback should end.
  Future<void> disconnect();

  /// Release local resources; must never send Stop to a different/new session.
  Future<void> dispose();
}
