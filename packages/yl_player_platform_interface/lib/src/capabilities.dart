import 'dart:collection';

import 'media_source.dart';

/// A conservative device/source capability snapshot.
final class YlPlayerCapabilities {
  YlPlayerCapabilities({
    Set<String> hardwareVideoCodecs = const <String>{},
    Set<YlFormatHint> supportedFormats = const <YlFormatHint>{},
    this.maxConcurrentVideoDecoders = 1,
    this.maxWidth,
    this.maxHeight,
  }) : hardwareVideoCodecs = UnmodifiableSetView<String>(
         Set<String>.of(hardwareVideoCodecs),
       ),
       supportedFormats = UnmodifiableSetView<YlFormatHint>(
         Set<YlFormatHint>.of(supportedFormats),
       );

  final Set<String> hardwareVideoCodecs;
  final Set<YlFormatHint> supportedFormats;
  final int maxConcurrentVideoDecoders;
  final int? maxWidth;
  final int? maxHeight;
}
