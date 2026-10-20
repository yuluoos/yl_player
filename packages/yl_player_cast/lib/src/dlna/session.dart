import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models.dart';
import '../provider.dart';
import 'description.dart';
import 'discovery.dart';
import 'transport.dart';

class DlnaSession implements YlCastRemoteSession {
  DlnaSession(
    this.description,
    this.network,
    this.onClose, {
    this.fmp4Verified = false,
  }) : _http = DlnaTransport(timeout: network.requestTimeout) {
    _schedulePoll();
  }
  final DlnaDescription description;
  final YlDlnaNetworkConfig network;
  final Future<void> Function() onClose;
  final bool fmp4Verified;
  final DlnaTransport _http;
  final _state = ValueNotifier(const YlCastPlaybackState());
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  Timer? _pollTimer;
  bool _closed = false;
  bool _live = false;
  int _pollFailures = 0;
  @override
  YlCastDevice get device => description.device;
  @override
  ValueListenable<YlCastPlaybackState> get state => _state;
  @override
  YlCastCapabilities get capabilities => YlCastCapabilities(
    pause: description.av.has('Pause'),
    seek: description.av.has('Seek') && description.av.absoluteSeek && !_live,
    volume: description.rendering?.has('SetVolume') ?? false,
    mute: description.rendering?.has('SetMute') ?? false,
  );

  Future<void> _enqueue(Future<void> Function() operation) {
    if (_closed) {
      return Future.error(const YlCastException('cast.session_closed'));
    }
    final result = _tail.then((_) async {
      if (_closed) throw const YlCastException('cast.session_closed');
      await operation();
    });
    _tail = result.catchError((Object _) {});
    return result;
  }

  Future<void> _av(
    String action, [
    Map<String, String> arguments = const {},
  ]) async {
    await description.av.call(_http, action, {'InstanceID': '0', ...arguments});
  }

  Future<void> _render(String action, Map<String, String> arguments) async {
    final service = description.rendering;
    if (service == null) throw const YlCastException('cast.action_unsupported');
    await service.call(_http, action, {
      'InstanceID': '0',
      'Channel': 'Master',
      ...arguments,
    });
  }

  @override
  Future<void> load(YlCastRequest request) => _enqueue(() async {
    final assessment = description.assess(request, fmp4Verified: fmp4Verified);
    if (!assessment.isSupported) {
      throw YlCastException(assessment.reason ?? 'cast.format_unverified');
    }
    validateHttpUri(request.uri);
    final metadata =
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="0" restricted="1"><dc:title>${escapeXml(request.title)}</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="http-get:*:${escapeXml(request.contentType)}:*">${escapeXml(request.uri.toString())}</res>'
        '</item></DIDL-Lite>';
    await _av('SetAVTransportURI', {
      'CurrentURI': request.uri.toString(),
      'CurrentURIMetaData': metadata,
    });
    _live = request.isLive;
    if (request.startPosition > Duration.zero && capabilities.seek) {
      await _av('Seek', {
        'Unit': 'REL_TIME',
        'Target': _timestamp(request.startPosition),
      });
    }
    if (!_closed) {
      _state.value = const YlCastPlaybackState(
        status: YlCastPlaybackStatus.loading,
      );
    }
  });
  @override
  Future<void> play() => _enqueue(() => _av('Play', {'Speed': '1'}));
  @override
  Future<void> pause() => _enqueue(() => _av('Pause'));
  @override
  Future<void> stop() => _enqueue(() async {
    await _av('Stop');
    if (!_closed) {
      _state.value = const YlCastPlaybackState(
        status: YlCastPlaybackStatus.stopped,
      );
    }
  });
  @override
  Future<void> seek(Duration position) => _enqueue(() async {
    if (!capabilities.seek || position.isNegative) {
      throw const YlCastException('cast.seek_unsupported');
    }
    await _av('Seek', {'Unit': 'REL_TIME', 'Target': _timestamp(position)});
  });
  @override
  Future<void> setVolume(double volume) => _enqueue(() async {
    if (!volume.isFinite || volume < 0 || volume > 1) {
      throw const YlCastException('cast.invalid_volume');
    }
    final service = description.rendering;
    if (service == null) throw const YlCastException('cast.action_unsupported');
    final raw =
        (service.volumeMin +
                ((volume * (service.volumeMax - service.volumeMin)) /
                            service.volumeStep)
                        .round() *
                    service.volumeStep)
            .clamp(service.volumeMin, service.volumeMax);
    await _render('SetVolume', {'DesiredVolume': '$raw'});
  });
  @override
  Future<void> setMuted(bool muted) =>
      _enqueue(() => _render('SetMute', {'DesiredMute': muted ? '1' : '0'}));

  void _schedulePoll() {
    if (_closed) return;
    final millis =
        max(20, network.pollInterval.inMilliseconds) *
        (1 << min(_pollFailures, 4));
    _pollTimer = Timer(Duration(milliseconds: min(millis, 30000)), () async {
      try {
        await _enqueue(_poll);
        _pollFailures = 0;
      } on YlCastException catch (error) {
        _pollFailures++;
        if (!_closed) {
          _state.value = YlCastPlaybackState(
            status: YlCastPlaybackStatus.failed,
            failureCode: error.code,
          );
        }
      } finally {
        _schedulePoll();
      }
    });
  }

  Future<void> _poll() async {
    var status = _state.value.status;
    Duration? position;
    Duration? duration;
    double? volume;
    bool? muted;
    if (description.av.has('GetTransportInfo')) {
      final response = await description.av.call(_http, 'GetTransportInfo', {
        'InstanceID': '0',
      });
      status = switch (textOf(response, 'CurrentTransportState')) {
        'PLAYING' => YlCastPlaybackStatus.playing,
        'PAUSED_PLAYBACK' || 'PAUSED_RECORDING' => YlCastPlaybackStatus.paused,
        'STOPPED' || 'NO_MEDIA_PRESENT' => YlCastPlaybackStatus.stopped,
        'TRANSITIONING' => YlCastPlaybackStatus.loading,
        _ => YlCastPlaybackStatus.idle,
      };
    }
    if (description.av.has('GetPositionInfo')) {
      final response = await description.av.call(_http, 'GetPositionInfo', {
        'InstanceID': '0',
      });
      position = _parseTimestamp(textOf(response, 'RelTime'));
      duration = _live
          ? null
          : _parseTimestamp(textOf(response, 'TrackDuration'));
      if (duration == Duration.zero) duration = null;
    }
    final service = description.rendering;
    if (service != null && service.has('GetVolume')) {
      final response = await service.call(_http, 'GetVolume', {
        'InstanceID': '0',
        'Channel': 'Master',
      });
      final raw = double.tryParse(textOf(response, 'CurrentVolume'));
      if (raw != null && raw.isFinite) {
        volume =
            ((raw - service.volumeMin) /
                    (service.volumeMax - service.volumeMin))
                .clamp(0, 1);
      }
    }
    if (service != null && service.has('GetMute')) {
      final response = await service.call(_http, 'GetMute', {
        'InstanceID': '0',
        'Channel': 'Master',
      });
      final raw = textOf(response, 'CurrentMute');
      muted = switch (raw) {
        '1' || 'true' => true,
        '0' || 'false' => false,
        _ => null,
      };
    }
    if (!_closed) {
      _state.value = YlCastPlaybackState(
        status: status,
        position: position,
        duration: duration,
        volume: volume,
        muted: muted,
      );
    }
  }

  @override
  Future<void> disconnect() => dispose();
  @override
  Future<void> dispose() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _pollTimer?.cancel();
    _http.dispose();
    await _tail;
    try {
      await onClose();
    } finally {
      _state.dispose();
    }
  }
}

String _timestamp(Duration value) =>
    '${value.inHours.toString().padLeft(2, '0')}:'
    '${(value.inMinutes % 60).toString().padLeft(2, '0')}:'
    '${(value.inSeconds % 60).toString().padLeft(2, '0')}';
Duration? _parseTimestamp(String value) {
  final match = RegExp(
    r'^(\d+):([0-5]\d):([0-5]\d)(?:\.\d+)?$',
  ).firstMatch(value);
  if (match == null) return null;
  final hours = int.tryParse(match.group(1)!);
  if (hours == null || hours > 876000) return null;
  return Duration(
    hours: hours,
    minutes: int.parse(match.group(2)!),
    seconds: int.parse(match.group(3)!),
  );
}
