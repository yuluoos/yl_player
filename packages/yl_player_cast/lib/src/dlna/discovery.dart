import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models.dart';
import 'description.dart';
import 'transport.dart';

/// Production defaults use SSDP multicast. Alternate endpoints support
/// controlled networks and loopback interoperability tests.
class YlDlnaNetworkConfig {
  YlDlnaNetworkConfig({
    InternetAddress? ssdpAddress,
    this.ssdpPort = 1900,
    InternetAddress? bindAddress,
    this.discoveryDuration = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 5),
    this.pollInterval = const Duration(seconds: 2),
  }) : ssdpAddress = ssdpAddress ?? InternetAddress('239.255.255.250'),
       bindAddress = bindAddress ?? InternetAddress.anyIPv4;
  final InternetAddress ssdpAddress;
  final int ssdpPort;
  final InternetAddress bindAddress;
  final Duration discoveryDuration;
  final Duration requestTimeout;
  final Duration pollInterval;
}

class DlnaDiscovery {
  DlnaDiscovery(
    this.config,
    this.onDevices,
    this.onFailure, {
    Future<RawDatagramSocket> Function(InternetAddress, int)? bindSocket,
  }) : _bindSocket = bindSocket ?? RawDatagramSocket.bind;
  final Future<RawDatagramSocket> Function(InternetAddress, int) _bindSocket;
  final YlDlnaNetworkConfig config;
  final void Function(YlCastException) onFailure;
  final void Function(List<DlnaDescription>) onDevices;
  final _known = <String, DlnaDescription>{};
  final _advertised = <String, _Advertisement>{};
  final _pending = <String>{};
  RawDatagramSocket? _socket;
  DlnaTransport? _http;
  Timer? _expiry;
  int _generation = 0;

  Future<void> start() async {
    stop();
    final generation = _generation;
    final socket = await _bindSocket(config.bindAddress, 0);
    if (generation != _generation) {
      socket.close();
      return;
    }
    socket.writeEventsEnabled = false;
    _socket = socket;
    final http = _http = DlnaTransport(timeout: config.requestTimeout);
    socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final packet = socket.receive();
        if (packet == null || packet.data.length > 8192) return;
        _receive(packet.data, generation, http);
      },
      onError: (Object error) {
        if (generation != _generation) return;
        stop();
        onFailure(discoveryFailure(error));
      },
    );
    final search =
        'M-SEARCH * HTTP/1.1\r\nHOST: ${config.ssdpAddress.address}:${config.ssdpPort}\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n';
    socket.send(utf8.encode(search), config.ssdpAddress, config.ssdpPort);
    _expiry ??= Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _expire(),
    );
  }

  void _receive(List<int> bytes, int generation, DlnaTransport http) {
    if (generation != _generation) return;
    final message = latin1.decode(bytes);
    if (!message.startsWith('HTTP/1.1 200')) return;
    final headers = <String, String>{};
    for (final line in message.split('\r\n').skip(1)) {
      final colon = line.indexOf(':');
      if (colon > 0) {
        headers[line.substring(0, colon).toLowerCase()] = line
            .substring(colon + 1)
            .trim();
      }
    }
    final uuid = (headers['usn'] ?? '').split('::').first.toLowerCase();
    if (!RegExp(r'^uuid:[a-z0-9_-]{1,128}$').hasMatch(uuid)) return;
    final location = Uri.tryParse(headers['location'] ?? '');
    if (location == null) return;
    try {
      validateHttpUri(location);
    } on YlCastException {
      return;
    }
    final maxAge =
        int.tryParse(
          RegExp(
                r'max-age\s*=\s*"?(\d+)',
                caseSensitive: false,
              ).firstMatch(headers['cache-control'] ?? '')?.group(1) ??
              '',
        ) ??
        1800;
    final expiry = DateTime.now().add(
      Duration(seconds: maxAge.clamp(0, 86400)),
    );
    final previous = _advertised[uuid];
    if (previous?.location == location) {
      previous!.expiry = expiry;
      return;
    }
    if (previous == null && _advertised.length >= 128) return;
    _advertised[uuid] = _Advertisement(location, expiry);
    // Invalidate the control URLs immediately, including across rescans.
    if (_known.remove(uuid) != null) _publish();
    _schedule(generation, http);
  }

  void _schedule(int generation, DlnaTransport http) {
    if (generation != _generation) return;
    for (final entry in _advertised.entries) {
      if (_pending.length >= 8) break;
      if (_known.containsKey(entry.key) || _pending.contains(entry.key)) {
        continue;
      }
      _fetch(entry.key, entry.value, generation, http);
    }
  }

  void _fetch(
    String uuid,
    _Advertisement advertisement,
    int generation,
    DlnaTransport http,
  ) {
    _pending.add(uuid);
    unawaited(() async {
      try {
        final description = await DlnaDescription.read(
          http,
          advertisement.location,
          uuid,
        );
        if (generation != _generation ||
            !identical(_advertised[uuid], advertisement) ||
            !advertisement.expiry.isAfter(DateTime.now())) {
          return;
        }
        _known[uuid] = description;
        _publish();
      } on Object {
        // Malformed/unavailable advertised devices are not usable.
      } finally {
        if (generation == _generation) {
          _pending.remove(uuid);
          if (!_known.containsKey(uuid) &&
              identical(_advertised[uuid], advertisement)) {
            _advertised.remove(uuid);
          }
          // A changed LOCATION waits for its UUID's old request, so repeated
          // advertisements cannot bypass the active-request bound.
          _schedule(generation, http);
        }
      }
    }());
  }

  void _expire() {
    final now = DateTime.now();
    final stale = _advertised.keys
        .where((key) => !_advertised[key]!.expiry.isAfter(now))
        .toList();
    for (final key in stale) {
      _known.remove(key);
      _advertised.remove(key);
    }
    if (stale.isNotEmpty) _publish();
  }

  void _publish() => onDevices(List.unmodifiable(_known.values));
  void stop() {
    _generation++;
    _socket?.close();
    _socket = null;
    _http?.dispose();
    _http = null;
    _pending.clear();
    _advertised.removeWhere((uuid, _) => !_known.containsKey(uuid));
  }

  void dispose() {
    stop();
    _expiry?.cancel();
    _expiry = null;
    _known.clear();
    _advertised.clear();
  }
}

class _Advertisement {
  _Advertisement(this.location, this.expiry);
  final Uri location;
  DateTime expiry;
}

YlCastException discoveryFailure(Object error) {
  if (error is YlCastException) return error;
  if (error is SocketException && [1, 13].contains(error.osError?.errorCode)) {
    return const YlCastException('cast.network_permission_denied');
  }
  if (error is PlatformException && error.code == 'cast.multicast_permission') {
    return const YlCastException('cast.network_permission_denied');
  }
  return const YlCastException('cast.discovery_failed');
}
