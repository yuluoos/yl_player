import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_cast/src/dlna/provider.dart';
import 'package:yl_player_cast/src/models.dart';

void main() {
  setUpAll(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });
  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
  });
  late Receiver peer;
  late YlDlnaProvider provider;
  setUp(() async {
    peer = await Receiver.start();
    provider = YlDlnaProvider(
      network: YlDlnaNetworkConfig(
        ssdpAddress: InternetAddress.loopbackIPv4,
        ssdpPort: peer.udp.port,
        bindAddress: InternetAddress.loopbackIPv4,
        discoveryDuration: const Duration(seconds: 10),
        pollInterval: const Duration(milliseconds: 40),
        requestTimeout: const Duration(seconds: 2),
      ),
    );
  });
  tearDown(() async {
    await provider.dispose();
    await peer.close();
  });

  Future<YlCastDevice> discover() async {
    await provider.startDiscovery();
    await until(() => provider.devices.value.isNotEmpty);
    return provider.devices.value.single;
  }

  test('SSDP UUID deduplication and max-age expiration', () async {
    final device = await discover();
    // Expire an already discovered receiver; slow first-use HTTP/JIT startup
    // must not consume the one-second lease before it can be observed.
    peer.maxAge = 1;
    peer.announce('uuid:loopback');
    expect(device.id, 'uuid:loopback');
    expect(device.name, 'Living room');
    expect(peer.descriptionReads, 1);
    await until(
      () => provider.devices.value.isEmpty,
      timeout: const Duration(seconds: 3),
    );
  });

  for (final rescan in [false, true]) {
    test(
      'changed LOCATION refreshes control endpoint (rescan: $rescan)',
      () async {
        final oldDevice = await discover();
        if (rescan) {
          await provider.stopDiscovery();
          peer.lastSearch = null;
          await provider.startDiscovery();
          await until(() => peer.lastSearch != null);
        }
        final replacement = await Receiver.start();
        addTearDown(replacement.close);
        replacement.lastSearch = peer.lastSearch;
        replacement.announce('uuid:loopback');
        await until(() => replacement.descriptionReads == 1);
        await until(() => provider.devices.value.isNotEmpty);
        final session = await provider.connect(oldDevice);
        await session.play();
        expect(replacement.actions, contains('Play'));
        expect(peer.actions, isNot(contains('Play')));
        expect(provider.devices.value, hasLength(1));
      },
    );
  }

  test('SSDP waves keep at most eight description jobs active', () async {
    final gate = peer.descriptionGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await provider.startDiscovery();
    await until(() => peer.descriptionReads == 1);
    for (var i = 0; i < 20; i++) {
      peer.announce('uuid:parallel-$i');
      peer.announce('uuid:loopback');
    }
    await until(() => peer.descriptionReads == 8);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(peer.descriptionReads, 8);
    gate.complete();
    await until(() => provider.devices.value.length == 21);
    expect(peer.descriptionReads, 21);
  });

  test(
    'old delayed LOCATION cannot publish over the newest advertisement',
    () async {
      final publishedNames = <String>[];
      provider.devices.addListener(() {
        publishedNames.addAll(
          provider.devices.value.map((device) => device.name),
        );
      });
      peer.descriptionDelay = const Duration(milliseconds: 150);
      await provider.startDiscovery();
      await until(() => peer.descriptionReads == 1);
      final replacement = await Receiver.start();
      replacement.friendlyName = 'Moved receiver';
      addTearDown(replacement.close);
      replacement.lastSearch = peer.lastSearch;
      for (var i = 0; i < 3; i++) {
        replacement.announce('uuid:loopback');
      }
      await until(() => replacement.descriptionReads == 1);
      await until(() => provider.devices.value.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final session = await provider.connect(provider.devices.value.single);
      await session.play();
      expect(replacement.descriptionReads, 1);
      expect(replacement.actions, contains('Play'));
      expect(peer.actions, isNot(contains('Play')));
      expect(publishedNames, isNot(contains('Living room')));
    },
  );

  test(
    'device inventory never exceeds 128 across repeated SSDP waves',
    () async {
      await provider.dispose();
      provider = YlDlnaProvider(
        network: YlDlnaNetworkConfig(
          ssdpAddress: InternetAddress.loopbackIPv4,
          ssdpPort: peer.udp.port,
          bindAddress: InternetAddress.loopbackIPv4,
          discoveryDuration: const Duration(seconds: 30),
        ),
      );
      await discover();
      for (var wave = 0; wave < 18; wave++) {
        for (var i = 0; i < 7; i++) {
          peer.announce('uuid:device-$wave-$i');
        }
        await until(() => provider.devices.value.length == 1 + (wave + 1) * 7);
      }
      for (var i = 0; i < 12; i++) {
        peer.announce('uuid:final-$i');
      }
      await until(() => provider.devices.value.length == 128);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(provider.devices.value.length, 128);
      expect(peer.descriptionReads, 128);
    },
  );

  test('cancelled discovery never publishes a delayed description', () async {
    peer.descriptionDelay = const Duration(milliseconds: 150);
    await provider.startDiscovery();
    await until(() => peer.descriptionReads > 0);
    await provider.stopDiscovery();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(provider.devices.value, isEmpty);
  });

  test('protocolInfo wildcard does not claim HLS support', () async {
    peer.sink = 'http-get:*:video/mp4:*,http-get:*:*:*';
    final device = await discover();
    expect(
      (await provider.assess(device, media('video/mp4'))).support,
      YlCastSupport.supported,
    );
    expect(
      (await provider.assess(
        device,
        media('application/vnd.apple.mpegurl'),
      )).support,
      YlCastSupport.unknown,
    );
    final session = await provider.connect(device);
    await expectLater(
      session.load(media('application/vnd.apple.mpegurl')),
      throwsA(
        isA<YlCastException>().having(
          (e) => e.code,
          'code',
          'cast.format_unverified',
        ),
      ),
    );
    expect(peer.actions.where((a) => a == 'SetAVTransportURI'), isEmpty);
  });

  test(
    'uses advertised service version and URLs, SOAP state and volume range',
    () async {
      final device = await discover();
      final session = await provider.connect(device);
      expect(session.capabilities.seek, isTrue);
      await session.load(media('video/mp4', title: 'A & B'));
      await session.play();
      await session.seek(const Duration(seconds: 65));
      await session.setVolume(.5);
      await session.setMuted(true);
      await until(
        () =>
            session.state.value.status == YlCastPlaybackStatus.playing &&
            session.state.value.volume != null,
      );
      expect(session.state.value.position, const Duration(seconds: 12));
      expect(session.state.value.duration, const Duration(seconds: 120));
      expect(session.state.value.volume, .5);
      expect(session.state.value.muted, true);
      expect(peer.lastVolume, '25');
      expect(peer.lastSeek, '00:01:05');
      expect(peer.lastUriBody, contains('A &amp;amp; B'));
      expect(peer.wrongControlPath, isFalse);
      expect(
        peer.soapActions,
        contains('"urn:schemas-upnp-org:service:AVTransport:2#Play"'),
      );
      await session.disconnect();
      final actionCount = peer.actions.length;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(peer.actions.length, actionCount);
      expect(peer.actions, isNot(contains('Stop')));
    },
  );

  test(
    'fMP4 HLS requires host-verified receiver in addition to MIME',
    () async {
      final device = await discover();
      final request = YlCastRequest(
        uri: Uri.parse('http://media.example/live.m3u8'),
        contentType: 'application/vnd.apple.mpegurl',
        isLive: true,
        requiresHlsFmp4: true,
      );
      expect(
        (await provider.assess(device, request)).support,
        YlCastSupport.unknown,
      );
      await provider.dispose();
      provider = YlDlnaProvider(
        network: YlDlnaNetworkConfig(
          ssdpAddress: InternetAddress.loopbackIPv4,
          ssdpPort: peer.udp.port,
          bindAddress: InternetAddress.loopbackIPv4,
        ),
        verifiedHlsFmp4DeviceIds: {'uuid:loopback'},
      );
      final verified = await discover();
      expect(
        (await provider.assess(verified, request)).support,
        YlCastSupport.supported,
      );
      final session = await provider.connect(verified);
      await session.load(request);
      expect(session.capabilities.seek, isFalse);
    },
  );

  test(
    'duplicate service advertisements do not multiply SCPD requests',
    () async {
      peer.extraServices = List.filled(
        30,
        peer.service('AVTransport', 2, 'av'),
      ).join();
      await discover();
      expect(peer.scpdReads, 3);
    },
  );

  test(
    'unsupported start position is rejected before replacing media',
    () async {
      peer.seekModes = '<allowedValue>TRACK_NR</allowedValue>';
      final device = await discover();
      final session = await provider.connect(device);
      final request = YlCastRequest(
        uri: Uri.parse('http://media.example/video.mp4'),
        contentType: 'video/mp4',
        startPosition: const Duration(seconds: 10),
      );
      expect(
        (await provider.assess(device, request)).support,
        YlCastSupport.unsupported,
      );
      await expectLater(session.load(request), throwsA(isA<YlCastException>()));
      expect(peer.actions, isNot(contains('SetAVTransportURI')));
      final negative = YlCastRequest(
        uri: request.uri,
        contentType: 'video/mp4',
        startPosition: const Duration(seconds: -1),
      );
      expect(
        (await provider.assess(device, negative)).support,
        YlCastSupport.unsupported,
      );
    },
  );

  test('seek requires the receiver to declare REL_TIME support', () async {
    peer.seekModes = '<allowedValue>TRACK_NR</allowedValue>';
    final session = await provider.connect(await discover());
    expect(session.capabilities.seek, isFalse);
    await expectLater(
      session.seek(const Duration(seconds: 10)),
      throwsA(isA<YlCastException>()),
    );
    expect(peer.actions, isNot(contains('Seek')));
  });

  test(
    'failed discovery bind has a stable error and remains retryable',
    () async {
      await provider.dispose();
      provider = YlDlnaProvider(
        network: YlDlnaNetworkConfig(
          ssdpAddress: InternetAddress.loopbackIPv4,
          ssdpPort: peer.udp.port,
          bindAddress: InternetAddress('192.0.2.42'),
        ),
      );
      await expectLater(
        provider.startDiscovery(),
        throwsA(
          isA<YlCastException>().having(
            (e) => e.code,
            'code',
            'cast.discovery_failed',
          ),
        ),
      );
      await provider.stopDiscovery();
    },
  );

  test(
    'malformed receiver timestamps stay unknown without crashing polling',
    () async {
      peer.positionValue = '999999999999999999999999999999999999:00:00';
      final session = await provider.connect(await discover());
      await until(() => session.state.value.volume != null);
      expect(session.state.value.position, isNull);
      await session.load(
        YlCastRequest(
          uri: Uri.parse('http://media.example/live.m3u8'),
          contentType: 'application/vnd.apple.mpegurl',
          isLive: true,
        ),
      );
      await until(() => session.state.value.volume != null);
      expect(session.state.value.duration, isNull);
    },
  );

  test(
    'polling backs off after receiver failures and disposal ends requests',
    () async {
      peer.faultAction = 'GetTransportInfo';
      final session = await provider.connect(await discover());
      await until(() => session.state.value.failureCode == 'cast.upnp_701');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        peer.actions.where((a) => a == 'GetTransportInfo').length,
        lessThanOrEqualTo(4),
      );
      await session.dispose();
      final count = peer.actions.length;
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(peer.actions.length, count);
    },
  );

  test(
    'replacement closes old session so its commands cannot stop new playback',
    () async {
      final device = await discover();
      final previous = await provider.connect(device);
      final current = await provider.connect(device);
      await current.play();
      await expectLater(
        previous.stop(),
        throwsA(
          isA<YlCastException>().having(
            (e) => e.code,
            'code',
            'cast.session_closed',
          ),
        ),
      );
      expect(peer.actions, isNot(contains('Stop')));
    },
  );

  test('HTTP 200 unrelated XML cannot acknowledge a media load', () async {
    final session = await provider.connect(await discover());
    for (final body in [
      '<html><body>OK</body></html>',
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:PlayResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:2"/></s:Body></s:Envelope>',
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:SetAVTransportURIResponse xmlns:u="urn:unrelated"/></s:Body></s:Envelope>',
    ]) {
      peer.soapOverride = body;
      await expectLater(
        session.load(media('video/mp4')),
        throwsA(
          isA<YlCastException>().having(
            (e) => e.code,
            'code',
            'cast.invalid_soap',
          ),
        ),
      );
    }
    expect(session.state.value.status, isNot(YlCastPlaybackStatus.loading));
  });

  test('SOAP UPnP faults have stable redacted codes', () async {
    final session = await provider.connect(await discover());
    peer.faultAction = 'Play';
    await expectLater(
      session.play(),
      throwsA(
        isA<YlCastException>().having((e) => e.code, 'code', 'cast.upnp_701'),
      ),
    );
  });

  test('description rejects DTD, excessive depth and redirects', () async {
    for (final body in [
      '<!DOCTYPE root [<!ENTITY x "secret">]><root/>',
      '${List.filled(34, '<x>').join()}${List.filled(34, '</x>').join()}',
    ]) {
      peer.descriptionOverride = body;
      await provider.startDiscovery();
      await until(() => peer.descriptionReads > 0);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await provider.stopDiscovery();
      expect(provider.devices.value, isEmpty);
      peer.descriptionReads = 0;
    }
    peer.descriptionOverride = null;
    peer.redirect = true;
    await provider.startDiscovery();
    await until(() => peer.descriptionReads > 0);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(provider.devices.value, isEmpty);
    expect(peer.redirectReads, 0);
  });
}

YlCastRequest media(String type, {String title = ''}) => YlCastRequest(
  uri: Uri.parse('http://media.example/video.mp4'),
  contentType: type,
  title: title,
);

Future<void> until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for receiver state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class Receiver {
  Receiver(this.http, this.udp);
  Datagram? lastSearch;
  final HttpServer http;
  final RawDatagramSocket udp;
  int maxAge = 30;
  int descriptionReads = 0;
  int scpdReads = 0;
  String extraServices = '';
  String friendlyName = 'Living room';
  int redirectReads = 0;
  bool redirect = false;
  bool wrongControlPath = false;
  Duration descriptionDelay = Duration.zero;
  Completer<void>? descriptionGate;
  String? descriptionOverride;
  String? faultAction;
  String? soapOverride;
  String sink =
      'http-get:*:video/mp4:*,http-get:*:application/vnd.apple.mpegurl:*';
  final actions = <String>[];
  final soapActions = <String>[];
  String seekModes = '<allowedValue>REL_TIME</allowedValue>';
  String positionValue = '00:00:12';
  String? lastVolume;
  String? lastSeek;
  String? lastUriBody;
  static Future<Receiver> start() async {
    final p = Receiver(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    p.udp.listen((e) {
      if (e != RawSocketEvent.read) return;
      final packet = p.udp.receive();
      if (packet == null) return;
      p.lastSearch = packet;
      for (var i = 0; i < 3; i++) {
        p.announce('uuid:loopback');
      }
    });
    p.http.listen(p.handle);
    return p;
  }

  void announce(String uuid) {
    final search = lastSearch!;
    final location = Uri.parse(
      'http://127.0.0.1:${http.port}/description',
    ).replace(queryParameters: {'udn': uuid});
    udp.send(
      utf8.encode(
        'HTTP/1.1 200 OK\r\nUSN: $uuid::urn:schemas-upnp-org:device:MediaRenderer:1\r\nLOCATION: $location\r\nCACHE-CONTROL: max-age=$maxAge\r\n\r\n',
      ),
      search.address,
      search.port,
    );
  }

  Future<void> handle(HttpRequest req) async {
    if (req.uri.path == '/description') {
      descriptionReads++;
      await descriptionGate?.future;
      await Future<void>.delayed(descriptionDelay);
      if (redirect) {
        req.response.statusCode = 302;
        req.response.headers.set('location', '/redirect');
      } else {
        req.response.write(
          descriptionOverride ??
              '''<root><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>$friendlyName</friendlyName><UDN>${req.uri.queryParameters['udn'] ?? 'uuid:loopback'}</UDN><serviceList>${service('AVTransport', 2, 'av')}${service('RenderingControl', 1, 'rc')}${service('ConnectionManager', 1, 'cm')}$extraServices</serviceList></device></root>''',
        );
      }
    } else if (req.uri.path == '/redirect') {
      redirectReads++;
    } else if (req.uri.path.startsWith('/scpd/')) {
      scpdReads++;
      final names = req.uri.path.endsWith('av')
          ? [
              'SetAVTransportURI',
              'Play',
              'Pause',
              'Stop',
              'Seek',
              'GetTransportInfo',
              'GetPositionInfo',
            ]
          : req.uri.path.endsWith('rc')
          ? ['SetVolume', 'GetVolume', 'SetMute', 'GetMute']
          : ['GetProtocolInfo'];
      req.response.write(
        '<scpd><actionList>${names.map((a) => '<action><name>$a</name></action>').join()}</actionList><serviceStateTable><stateVariable><name>A_ARG_TYPE_SeekMode</name><allowedValueList>$seekModes</allowedValueList></stateVariable><stateVariable><name>Volume</name><allowedValueRange><minimum>0</minimum><maximum>50</maximum><step>1</step></allowedValueRange></stateVariable></serviceStateTable></scpd>',
      );
    } else {
      final header = req.headers.value('soapaction') ?? '';
      soapActions.add(header);
      final action = header.split('#').last.replaceAll('"', '');
      actions.add(action);
      final body = await utf8.decoder.bind(req).join();
      final expectedPath = header.contains('AVTransport')
          ? '/control/av'
          : header.contains('RenderingControl')
          ? '/control/rc'
          : '/control/cm';
      if (req.uri.path != expectedPath) wrongControlPath = true;
      if (action == 'SetVolume') {
        lastVolume = RegExp(
          r'<DesiredVolume>(.*?)</DesiredVolume>',
        ).firstMatch(body)?.group(1);
      }
      if (action == 'Seek') {
        lastSeek = RegExp(r'<Target>(.*?)</Target>').firstMatch(body)?.group(1);
      }
      if (action == 'SetAVTransportURI') lastUriBody = body;
      if (soapOverride != null) {
        req.response.write(soapOverride);
      } else if (action == faultAction) {
        req.response.statusCode = 500;
        req.response.write(
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail><UPnPError><errorCode>701</errorCode><errorDescription>private</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>',
        );
      } else {
        final result = switch (action) {
          'GetProtocolInfo' => '<Sink>$sink</Sink>',
          'GetTransportInfo' =>
            '<CurrentTransportState>PLAYING</CurrentTransportState>',
          'GetPositionInfo' =>
            '<TrackDuration>00:02:00</TrackDuration><RelTime>$positionValue</RelTime>',
          'GetVolume' => '<CurrentVolume>25</CurrentVolume>',
          'GetMute' => '<CurrentMute>1</CurrentMute>',
          _ => '',
        };
        req.response.write(
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:${action}Response xmlns:u="${header.split('#').first.replaceAll('"', '')}">$result</u:${action}Response></s:Body></s:Envelope>',
        );
      }
    }
    await req.response.close();
  }

  String service(String name, int version, String key) =>
      '<service><serviceType>urn:schemas-upnp-org:service:$name:$version</serviceType><SCPDURL>/scpd/$key</SCPDURL><controlURL>/control/$key</controlURL></service>';
  Future<void> close() async {
    udp.close();
    await http.close(force: true);
  }
}
