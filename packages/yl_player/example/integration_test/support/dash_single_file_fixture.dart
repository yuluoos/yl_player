import 'dart:typed_data';

/// Packs only the owned, explicit SegmentList fixture; never used by playback.
(String, Map<String, Uint8List>) packDashSingleFile(
  String manifest,
  Map<String, Uint8List> files,
) {
  final packed = <String, Uint8List>{};
  final xml = manifest.replaceAllMapped(
    RegExp(
      r'<Period[^>]*><BaseURL>(period\d+)/</BaseURL>.*?</Period>',
      dotAll: true,
    ),
    (period) => period.group(0)!.replaceAllMapped(
      RegExp(
        r'<Representation id="([^"]+)"[^>]*>.*?</Representation>',
        dotAll: true,
      ),
      (representation) {
        final name = 'packed-${representation.group(1)}.m4s';
        final builder = BytesBuilder(copy: true);
        var body = representation
            .group(0)!
            .replaceFirst('>', '><BaseURL>$name</BaseURL>');
        body = body.replaceAllMapped(
          RegExp(r'<(Initialization|SegmentURL) (sourceURL|media)="([^"]+)"/>'),
          (reference) {
            final bytes = files['/${period.group(1)}/${reference.group(3)}']!;
            if (bytes.isEmpty) throw StateError('Empty owned fixture resource');
            final start = builder.length;
            builder.add(bytes);
            final attr = reference.group(1) == 'Initialization'
                ? 'range'
                : 'mediaRange';
            return '<${reference.group(1)} $attr="$start-${builder.length - 1}"/>';
          },
        );
        if (builder.isEmpty) {
          throw StateError('Expected owned SegmentList fixture');
        }
        packed['/${period.group(1)}/$name'] = builder.takeBytes();
        return body;
      },
    ),
  );
  if (packed.isEmpty) throw StateError('Expected owned multi-Period fixture');
  return (xml, packed);
}
