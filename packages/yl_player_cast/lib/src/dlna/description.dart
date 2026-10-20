import 'package:xml/xml.dart';

import '../models.dart';
import 'transport.dart';

class DlnaService {
  DlnaService(this.type, this.controlUrl, this.scpdUrl);
  final String type;
  final Uri controlUrl;
  final Uri scpdUrl;
  final Set<String> actions = {};
  int volumeMin = 0;
  int volumeMax = 100;
  int volumeStep = 1;
  bool absoluteSeek = false;
  bool has(String action) => actions.contains(action);
  Future<XmlDocument> call(
    DlnaTransport http,
    String action,
    Map<String, String> args,
  ) {
    if (!has(action)) throw const YlCastException('cast.action_unsupported');
    return http.soap(controlUrl, type, action, args);
  }
}

class DlnaDescription {
  DlnaDescription(this.device, this.av, this.rendering, this.mimeTypes);
  final YlCastDevice device;
  final DlnaService av;
  final DlnaService? rendering;
  final Set<String> mimeTypes;

  static Future<DlnaDescription> read(
    DlnaTransport http,
    Uri location,
    String uuid,
  ) async {
    final document = await http.get(location);
    final renderer = elements(document, 'device')
        .where(
          (d) => d.childElements.any(
            (e) =>
                e.name.local == 'deviceType' &&
                RegExp(
                  r'^urn:schemas-upnp-org:device:MediaRenderer:\d+$',
                ).hasMatch(e.innerText.trim()),
          ),
        )
        .firstOrNull;
    if (renderer == null ||
        textOf(renderer, 'UDN').toLowerCase() != uuid.toLowerCase()) {
      throw const YlCastException('cast.invalid_device');
    }
    final baseText = textOf(document, 'URLBase');
    final base = baseText.isEmpty ? location : location.resolve(baseText);
    validateHttpUri(base);
    final services = <String, DlnaService>{};
    final list = renderer.childElements
        .where((e) => e.name.local == 'serviceList')
        .firstOrNull;
    for (final entry in list?.childElements ?? <XmlElement>[]) {
      final type = textOf(entry, 'serviceType');
      final match = RegExp(
        r'^urn:schemas-upnp-org:service:(AVTransport|RenderingControl|ConnectionManager):\d+$',
      ).firstMatch(type);
      if (match == null || services.containsKey(match.group(1))) continue;
      final control = textOf(entry, 'controlURL');
      final scpd = textOf(entry, 'SCPDURL');
      if (control.isEmpty || scpd.isEmpty) continue;
      final service = DlnaService(
        type,
        base.resolve(control),
        base.resolve(scpd),
      );
      validateHttpUri(service.controlUrl);
      validateHttpUri(service.scpdUrl);
      final schema = await http.get(service.scpdUrl);
      service.actions.addAll(
        elements(schema, 'action').map((a) => textOf(a, 'name')),
      );
      for (final variable in elements(schema, 'stateVariable')) {
        final name = textOf(variable, 'name');
        if (name == 'Volume') {
          service.volumeMin = int.tryParse(textOf(variable, 'minimum')) ?? 0;
          service.volumeMax = int.tryParse(textOf(variable, 'maximum')) ?? 100;
          service.volumeStep = int.tryParse(textOf(variable, 'step')) ?? 1;
          if (service.volumeMin < 0 ||
              service.volumeMax <= service.volumeMin ||
              service.volumeStep <= 0) {
            service.actions.removeAll(['GetVolume', 'SetVolume']);
          }
        }
        if (name == 'A_ARG_TYPE_SeekMode') {
          service.absoluteSeek = elements(
            variable,
            'allowedValue',
          ).any((v) => v.innerText == 'REL_TIME');
        }
      }
      services[match.group(1)!] = service;
    }
    final av = services['AVTransport'];
    if (av == null || !av.has('SetAVTransportURI') || !av.has('Play')) {
      throw const YlCastException('cast.invalid_device');
    }
    final mimeTypes = <String>{};
    final cm = services['ConnectionManager'];
    if (cm != null && cm.has('GetProtocolInfo')) {
      try {
        final info = await cm.call(http, 'GetProtocolInfo', {});
        for (final entry in textOf(info, 'Sink').split(',')) {
          final fields = entry.trim().split(':');
          if (fields.length >= 4 && fields[0].toLowerCase() == 'http-get') {
            mimeTypes.add(fields[2].toLowerCase());
          }
        }
      } on YlCastException {
        /* Unknown support must remain unknown. */
      }
    }
    return DlnaDescription(
      YlCastDevice(
        id: uuid,
        providerId: 'dlna',
        name: textOf(renderer, 'friendlyName'),
      ),
      av,
      services['RenderingControl'],
      mimeTypes,
    );
  }

  YlCastAssessment assess(YlCastRequest request, {bool fmp4Verified = false}) {
    if (request.startPosition.isNegative) {
      return const YlCastAssessment(
        YlCastSupport.unsupported,
        reason: 'cast.invalid_position',
      );
    }
    if (request.startPosition > Duration.zero &&
        (request.isLive || !av.has('Seek') || !av.absoluteSeek)) {
      return const YlCastAssessment(
        YlCastSupport.unsupported,
        reason: 'cast.seek_unsupported',
      );
    }
    if (!['http', 'https'].contains(request.uri.scheme) ||
        request.uri.host.isEmpty ||
        request.uri.userInfo.isNotEmpty) {
      return const YlCastAssessment(
        YlCastSupport.unsupported,
        reason: 'cast.delivery_unsupported',
      );
    }
    final mime = request.contentType.toLowerCase().split(';').first.trim();
    final hls = [
      'application/vnd.apple.mpegurl',
      'application/x-mpegurl',
      'audio/mpegurl',
      'audio/x-mpegurl',
    ];
    final supported =
        mimeTypes.contains(mime) ||
        (hls.contains(mime) && mimeTypes.any(hls.contains));
    if (supported && request.requiresHlsFmp4 && !fmp4Verified) {
      return const YlCastAssessment(
        YlCastSupport.unknown,
        reason: 'cast.hls_fmp4_unverified',
      );
    }
    if (supported) return const YlCastAssessment(YlCastSupport.supported);
    if (mimeTypes.isEmpty || mimeTypes.contains('*')) {
      return const YlCastAssessment(
        YlCastSupport.unknown,
        reason: 'cast.format_unverified',
      );
    }
    return const YlCastAssessment(
      YlCastSupport.unsupported,
      reason: 'cast.format_unsupported',
    );
  }
}
