import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'local_player.dart';
import 'models.dart';
import 'provider.dart';

/// An explicit local session to pause after the receiver accepts the source.
/// Keep the source/options used to create this session for returning locally.
class YlCastHandoff {
  const YlCastHandoff({
    required this.session,
    required this.source,
    this.options = const YlLoadOptions(),
  });
  final YlCastLocalSession session;
  final YlMediaSource source;
  final YlLoadOptions options;
}

class YlCastSnapshot {
  const YlCastSnapshot({
    this.device,
    this.playback = const YlCastPlaybackState(),
    this.connecting = false,
    this.hostedMedia = false,
    this.airPlayActive = false,
    this.failureCode,
    this.canDetachKeepingPlayback = false,
    this.capabilities,
  });
  final YlCastDevice? device;
  final YlCastPlaybackState playback;
  final bool connecting;
  final bool hostedMedia;
  final bool airPlayActive;
  final String? failureCode;
  bool get routeConflict => airPlayActive && device != null;
  final bool canDetachKeepingPlayback;

  /// Effective controls for the active session, including delivery restrictions.
  final YlCastCapabilities? capabilities;
}

/// Owns providers and remote resources, but never owns [player] or [mediaDelivery].
/// A new remote load requires stopping/detaching the previous remote session.
class YlCastController {
  YlCastController({
    required List<YlCastProvider> providers,
    this.player,
    this.mediaDelivery,
  }) : _providers = List.unmodifiable(providers) {
    if (providers.map((p) => p.id).toSet().length != providers.length) {
      throw ArgumentError('Provider IDs must be unique');
    }
    for (final provider in _providers) {
      provider.devices.addListener(_updateDevices);
      provider.discovery.addListener(_updateDiscovery);
    }
    player?.airPlayState.addListener(_updateRoute);
    _updateDevices();
    _updateDiscovery();
    _updateRoute();
  }

  final YlCastLocalPlayer? player;

  /// Caller-owned optional delivery service; preferred over player compatibility.
  final YlMediaDeliveryProvider? mediaDelivery;
  final List<YlCastProvider> _providers;
  final _state = ValueNotifier(const YlCastSnapshot());
  final _devices = ValueNotifier<List<YlCastDevice>>(const []);
  final _discovery = ValueNotifier<Map<String, YlCastDiscoveryState>>(const {});
  ValueListenable<YlCastSnapshot> get state => _state;
  ValueListenable<List<YlCastDevice>> get devices => _devices;

  /// Discovery activity and errors keyed by provider ID.
  ValueListenable<Map<String, YlCastDiscoveryState>> get discovery =>
      _discovery;
  YlCastRemoteSession? _remote;
  YlMediaDeliveryLease? _lease;
  YlMediaDeliveryPreparation? _preparation;
  VoidCallback? _remoteListener;
  VoidCallback? _leaseListener;
  YlCastHandoff? _handoff;
  YlCastLocalSession? _ownedAirPlay;
  Duration? _localPosition;
  bool _localWasPlaying = false;
  bool _localWasLive = false;
  bool _disposed = false;
  int _generation = 0;
  int _discoveryGeneration = 0;
  Future<void> _tail = Future.value();
  Future<void>? _disposeFuture;

  Future<T> _serial<T>(Future<T> Function() action) {
    if (_disposed) return Future.error(const YlCastException('cast.disposed'));
    final result = _tail.then((_) {
      _check();
      return action();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _check([int? generation]) {
    if (_disposed) throw const YlCastException('cast.disposed');
    if (generation != null && generation != _generation) {
      throw const YlCastException('cast.cancelled');
    }
  }

  bool get _airPlayActive => player?.airPlayState.value.active ?? false;
  void _updateRoute() {
    if (!_disposed) {
      _publish(
        failure: _airPlayActive && _remote != null
            ? 'cast.route_conflict'
            : _state.value.failureCode,
      );
    }
  }

  void _updateDevices() {
    if (_disposed) return;
    _devices.value = List.unmodifiable(
      _providers.expand((provider) => provider.devices.value),
    );
  }

  void _publish({bool connecting = false, String? failure}) {
    if (_disposed) return;
    final capabilities = _remote?.capabilities;
    final effective = capabilities == null
        ? null
        : YlCastCapabilities(
            pause: capabilities.pause,
            seek: capabilities.seek && !(_lease?.isLive ?? false),
            volume: capabilities.volume,
            mute: capabilities.mute,
            canDetachKeepingPlayback:
                _lease == null && capabilities.canDetachKeepingPlayback,
          );
    _state.value = YlCastSnapshot(
      device: _remote?.device,
      playback: _remote?.state.value ?? const YlCastPlaybackState(),
      connecting: connecting,
      hostedMedia: _lease != null,
      capabilities: effective,
      canDetachKeepingPlayback: effective?.canDetachKeepingPlayback ?? false,
      airPlayActive: _airPlayActive,
      failureCode: _airPlayActive && _remote != null
          ? 'cast.route_conflict'
          : failure,
    );
  }

  void _updateDiscovery() {
    if (_disposed) return;
    _discovery.value = Map.unmodifiable({
      for (final provider in _providers) provider.id: provider.discovery.value,
    });
  }

  YlCastProvider _provider(YlCastDevice device) =>
      _providers.where((p) => p.id == device.providerId).firstOrNull ??
      (throw const YlCastException('cast.provider_unavailable'));

  Future<void> startDiscovery() {
    final generation = ++_discoveryGeneration;
    return _serial(() async {
      for (final provider in _providers) {
        if (generation != _discoveryGeneration) return;
        await provider.startDiscovery();
      }
    });
  }

  Future<void> stopDiscovery() async {
    _check();
    _discoveryGeneration++;
    await Future.wait(_providers.map((provider) => provider.stopDiscovery()));
  }

  bool _needsDelivery(YlMediaSource source) =>
      source is YlNetworkSource &&
      (source.uri.scheme == 'rtmp' ||
          source.uri.scheme == 'rtmps' ||
          source.format == YlMediaFormat.flv ||
          (source.format == YlMediaFormat.automatic &&
              source.uri.path.toLowerCase().endsWith('.flv')));

  YlCastRequest _request(
    YlMediaSource source, {
    String? contentType,
    String title = '',
    Duration startPosition = Duration.zero,
  }) {
    if (startPosition.isNegative) {
      throw const YlCastException('cast.invalid_position');
    }
    if (source is! YlNetworkSource || source.drm != null) {
      throw const YlCastException('cast.source_unsupported');
    }
    if (source.networkPolicy.kind != YlNetworkPolicyKind.platformDefault) {
      throw const YlCastException('cast.network_policy_unsupported');
    }
    if (_needsDelivery(source)) {
      if (source.intent == YlStreamIntent.onDemand ||
          (source.format != YlMediaFormat.automatic &&
              source.format != YlMediaFormat.flv)) {
        throw const YlCastException('cast.source_unsupported');
      }
      if (mediaDelivery == null && !(player?.supportsMediaDelivery ?? false)) {
        throw const YlCastException('cast.delivery_unavailable');
      }
      if (startPosition != Duration.zero) {
        throw const YlCastException('cast.seek_unsupported');
      }
      return YlCastRequest(
        uri: Uri.parse('https://delivery.invalid/live.m3u8'),
        contentType: 'application/vnd.apple.mpegurl',
        isLive: true,
        requiresHlsFmp4: true,
        title: title,
        startPosition: startPosition,
      );
    }
    final uri = source.uri;
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const YlCastException('cast.source_unsupported');
    }
    if (source.request.headers.isNotEmpty ||
        source.request.credentials.isNotEmpty) {
      throw const YlCastException('cast.headers_unsupported');
    }
    final mime =
        contentType ??
        switch (source.format) {
          YlMediaFormat.hls => 'application/vnd.apple.mpegurl',
          YlMediaFormat.mp4 => 'video/mp4',
          YlMediaFormat.automatic
              when uri.path.toLowerCase().endsWith('.m3u8') =>
            'application/vnd.apple.mpegurl',
          YlMediaFormat.automatic
              when uri.path.toLowerCase().endsWith('.mp4') =>
            'video/mp4',
          _ => throw const YlCastException('cast.format_unknown'),
        };
    return YlCastRequest(
      uri: uri,
      contentType: mime,
      title: title,
      isLive: source.intent == YlStreamIntent.live,
      startPosition: startPosition,
    );
  }

  Future<YlCastAssessment> assess(
    YlCastDevice device,
    YlMediaSource source, {
    String? contentType,
  }) async {
    _check();
    if (_airPlayActive) {
      return const YlCastAssessment(
        YlCastSupport.unsupported,
        reason: 'cast.route_conflict',
      );
    }
    try {
      final request = _request(source, contentType: contentType);
      return await _provider(device).assess(device, request);
    } on YlCastException catch (e) {
      return YlCastAssessment(YlCastSupport.unsupported, reason: e.code);
    }
  }

  /// Success acknowledges remote commands, never proves a displayed frame.
  Future<void> cast(
    YlCastDevice device,
    YlMediaSource source, {
    String? contentType,
    String title = '',
    bool autoplay = true,
    Duration startPosition = Duration.zero,
    YlCastHandoff? handoff,
  }) {
    final generation = _generation;
    return _serial(() async {
      _check(generation);
      if (_airPlayActive) throw const YlCastException('cast.route_conflict');
      if (_remote != null) throw const YlCastException('cast.session_active');
      if (handoff != null &&
          (player == null ||
              player!.state.sessionId != handoff.session.id ||
              handoff.source != source)) {
        throw const YlCastException('cast.local_session_stale');
      }
      final position = handoff == null
          ? startPosition
          : player!.state.timeline.isLive
          ? Duration.zero
          : player!.state.timeline.position;
      final localPosition = player?.state.timeline.position;
      final wasPlaying = player?.state.status == YlPlaybackStatus.playing;
      final wasLive = player?.state.timeline.isLive ?? false;
      var request = _request(
        source,
        contentType: contentType,
        title: title,
        startPosition: position,
      );
      if (handoff != null && wasLive && !request.isLive) {
        request = YlCastRequest(
          uri: request.uri,
          contentType: request.contentType,
          isLive: true,
          title: request.title,
          requiresHlsFmp4: request.requiresHlsFmp4,
        );
      }
      final provider = _provider(device);
      YlCastRemoteSession? remote;
      YlMediaDeliveryLease? lease;
      var localPaused = false;
      _publish(connecting: true);
      try {
        final assessment = await provider.assess(device, request);
        _check(generation);
        if (!assessment.isSupported) {
          throw YlCastException(assessment.reason ?? 'cast.format_unverified');
        }
        if (_needsDelivery(source)) {
          final preparation =
              mediaDelivery?.prepareMediaDelivery(source) ??
              player!.prepareMediaDelivery(source);
          _preparation = preparation;
          try {
            lease = await preparation.result;
          } finally {
            if (identical(_preparation, preparation)) _preparation = null;
          }
          _check(generation);
          request = YlCastRequest(
            uri: lease.uri,
            contentType: lease.contentType,
            isLive: lease.isLive,
            title: title,
            requiresHlsFmp4: true,
          );
        }
        remote = await provider.connect(device);
        _check(generation);
        await remote.load(request);
        _check(generation);
        if (_airPlayActive) throw const YlCastException('cast.route_conflict');
        if (lease != null &&
            lease.state.value.status != YlMediaDeliveryStatus.ready) {
          throw const YlCastException('cast.delivery_failed');
        }
        if (handoff != null) {
          await handoff.session.pause();
          localPaused = true;
        }
        if (autoplay) await remote.play();
        _check(generation);
        if (_airPlayActive) throw const YlCastException('cast.route_conflict');
        if (lease != null &&
            lease.state.value.status != YlMediaDeliveryStatus.ready) {
          throw const YlCastException('cast.delivery_failed');
        }
        _remote = remote;
        _lease = lease;
        _handoff = handoff;
        _localPosition = localPosition;
        _localWasPlaying = wasPlaying;
        _localWasLive = wasLive;
        final owned = remote;
        _remoteListener = () {
          if (!_disposed && identical(_remote, owned)) _publish();
        };
        remote.state.addListener(_remoteListener!);
        if (lease != null) {
          final ownedLease = lease;
          _leaseListener = () {
            if (identical(_lease, ownedLease) &&
                ownedLease.state.value.status != YlMediaDeliveryStatus.ready) {
              unawaited(
                _serial(() async {
                  if (!identical(_lease, ownedLease)) return;
                  try {
                    await _release(stop: true);
                  } finally {
                    _publish(failure: 'cast.delivery_failed');
                  }
                }).catchError((Object _) {}),
              );
            }
          };
          lease.state.addListener(_leaseListener!);
        }
        _publish();
      } on Object catch (error) {
        try {
          if (remote != null) {
            try {
              await remote.stop();
            } finally {
              await remote.dispose();
            }
          }
        } on Object {
          // Preserve the load failure while attempting all cleanup.
        } finally {
          try {
            await lease?.dispose();
          } on Object {
            /* Preserve load error. */
          }
        }
        if (localPaused && wasPlaying) {
          try {
            await handoff!.session.play();
          } on Object {
            /* May have been replaced externally. */
          }
        }
        _publish(
          failure: error is YlCastException ? error.code : 'cast.load_failed',
        );
        rethrow;
      }
    });
  }

  /// Cancels admission without waiting behind a pending network/media operation.
  Future<void> cancelPending() async {
    _check();
    _generation++;
    await _preparation?.cancel();
  }

  YlCastRemoteSession get _session =>
      _remote ?? (throw const YlCastException('cast.no_session'));
  Future<void> play() => _serial(() {
    if (_airPlayActive) throw const YlCastException('cast.route_conflict');
    return _session.play();
  });
  Future<void> pause() => _serial(() {
    if (!_session.capabilities.pause) {
      throw const YlCastException('cast.pause_unsupported');
    }
    return _session.pause();
  });
  Future<void> seek(Duration position) => _serial(() {
    if (position.isNegative ||
        !_session.capabilities.seek ||
        _lease?.isLive == true) {
      throw const YlCastException('cast.seek_unsupported');
    }
    return _session.seek(position);
  });
  Future<void> setVolume(double volume) => _serial(() {
    if (!volume.isFinite || volume < 0 || volume > 1) {
      throw const YlCastException('cast.invalid_volume');
    }
    if (!_session.capabilities.volume) {
      throw const YlCastException('cast.volume_unsupported');
    }
    return _session.setVolume(volume);
  });
  Future<void> setMuted(bool muted) => _serial(() {
    if (!_session.capabilities.mute) {
      throw const YlCastException('cast.mute_unsupported');
    }
    return _session.setMuted(muted);
  });
  Future<void> stop() => _serial(() async {
    try {
      await _release(stop: true);
    } finally {
      _handoff = null;
      try {
        await _stopOwnedAirPlay();
      } finally {
        _publish();
      }
    }
  });
  Future<void> disconnect({bool keepPlaying = false}) => _serial(() async {
    if (keepPlaying &&
        (_lease != null ||
            !(_remote?.capabilities.canDetachKeepingPlayback ?? true))) {
      throw const YlCastException('cast.detach_unsupported');
    }
    try {
      await _release(stop: !keepPlaying);
    } finally {
      _handoff = null;
      _publish();
    }
  });

  Future<void> _release({required bool stop}) async {
    final remote = _remote;
    final lease = _lease;
    _remote = null;
    _lease = null;
    if (_remoteListener != null) remote?.state.removeListener(_remoteListener!);
    if (_leaseListener != null) lease?.state.removeListener(_leaseListener!);
    _remoteListener = null;
    _leaseListener = null;
    try {
      if (stop) {
        await remote?.stop();
      } else {
        await remote?.disconnect();
      }
    } finally {
      try {
        await remote?.dispose();
      } finally {
        await lease?.dispose();
      }
    }
  }

  Future<YlCastLocalSession> returnToLocal() {
    final generation = _generation;
    return _serial(() async {
      _check(generation);
      final handoff = _handoff;
      if (handoff == null || player == null) {
        throw const YlCastException('cast.no_handoff');
      }
      if (_airPlayActive) throw const YlCastException('cast.route_conflict');
      if (player!.state.sessionId != handoff.session.id) {
        throw const YlCastException('cast.local_session_stale');
      }
      final position = _remote?.state.value.position ?? _localPosition;
      try {
        await _release(stop: true);
      } finally {
        _handoff = null;
        _publish();
      }
      // Stop/disposal can await network I/O. Ownership may change in that time.
      _check(generation);
      if (_airPlayActive) throw const YlCastException('cast.route_conflict');
      if (player!.state.sessionId != handoff.session.id) {
        throw const YlCastException('cast.local_session_stale');
      }
      final original = handoff.options;
      final session = await player!.load(
        handoff.source,
        options: YlLoadOptions(
          autoplay: _localWasPlaying,
          startPosition: _localWasLive ? null : position,
          bufferStrategy: original.bufferStrategy,
          videoConstraints: original.videoConstraints,
          decoderPolicyOverride: original.decoderPolicyOverride,
        ),
      );
      try {
        _check(generation);
      } on YlCastException {
        if (player!.state.sessionId == session.id) await player!.stop();
        rethrow;
      }
      return session;
    });
  }

  /// Selection remains in Apple's system route picker (YlAirPlayButton).
  Future<YlCastLocalSession> loadAirPlay(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) {
    final generation = _generation;
    return _serial(() async {
      _check(generation);
      if (_remote != null) throw const YlCastException('cast.route_conflict');
      final local = player;
      if (local == null) throw const YlCastException('cast.player_required');
      final session = await local.load(
        source,
        options: YlLoadOptions(
          airPlay: true,
          autoplay: options.autoplay,
          startPosition: options.startPosition,
          bufferStrategy: options.bufferStrategy,
          videoConstraints: options.videoConstraints,
          decoderPolicyOverride: options.decoderPolicyOverride,
        ),
      );
      _ownedAirPlay = session;
      try {
        _check(generation);
      } on YlCastException {
        await _stopOwnedAirPlay();
        rethrow;
      }
      return session;
    });
  }

  Future<void> _stopOwnedAirPlay() async {
    final session = _ownedAirPlay;
    _ownedAirPlay = null;
    if (session != null && player?.state.sessionId == session.id) {
      await player!.stop();
    }
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    _generation++;
    _discoveryGeneration++;
    player?.airPlayState.removeListener(_updateRoute);
    for (final provider in _providers) {
      provider.devices.removeListener(_updateDevices);
      provider.discovery.removeListener(_updateDiscovery);
    }
    try {
      try {
        await _preparation?.cancel();
      } finally {
        await _tail;
        try {
          await _release(stop: true);
        } finally {
          await _stopOwnedAirPlay();
        }
      }
    } finally {
      try {
        await Future.wait(_providers.map((p) => p.dispose()));
      } finally {
        _state.dispose();
        _devices.dispose();
        _discovery.dispose();
      }
    }
  }
}
