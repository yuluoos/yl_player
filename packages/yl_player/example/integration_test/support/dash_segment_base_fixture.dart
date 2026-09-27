import 'dart:typed_data';

/// Test-only packaging of the owned four-second AVC/AAC Period. No samples or
/// fragment timestamps are rewritten. Flat indexes address entire fragments.
(String, Map<String, Uint8List>) packDashSegmentBase(
  Map<String, Uint8List> files, {
  int version = 0,
}) {
  if (version != 0 && version != 1) throw ArgumentError.value(version);
  final packed = <String, Uint8List>{};
  final adaptations = <String>[];
  for (final track in [0, 1]) {
    final init = files['/period0/init-$track.m4s']!;
    final durations = track == 0
        ? [12288, 12288, 12288, 12288]
        : [47104, 48128, 48128, 48128, 512];
    final fragments = [
      for (var n = 1; n <= durations.length; n++)
        files['/period0/chunk-$track-${n.toString().padLeft(5, '0')}.m4s']!,
    ];
    final header = version == 0 ? 32 : 40;
    final index = ByteData(header + fragments.length * 12);
    index.setUint32(0, index.lengthInBytes);
    index.setUint32(4, 0x73696478);
    index.setUint8(8, version);
    index.setUint32(
      12,
      1,
    ); // Track IDs are local to each original init segment.
    index.setUint32(16, track == 0 ? 12288 : 48000);
    index.setUint16(header - 2, fragments.length);
    for (var n = 0; n < fragments.length; n++) {
      final entry = header + n * 12;
      index.setUint32(entry, fragments[n].length);
      index.setUint32(entry + 4, durations[n]);
      index.setUint32(entry + 8, 0x90000000);
    }
    final bytes = BytesBuilder(copy: true)
      ..add(init)
      ..add(index.buffer.asUint8List());
    for (final fragment in fragments) {
      bytes.add(fragment);
    }
    packed['/period0/indexed-$track.mp4'] = bytes.takeBytes();
    final kind = track == 0 ? 'video' : 'audio';
    final attrs = track == 0
        ? 'codecs="avc1.42c01e" bandwidth="350000" width="320" height="180"'
        : 'codecs="mp4a.40.2" bandwidth="64000" audioSamplingRate="48000"';
    adaptations.add(
      '''<AdaptationSet contentType="$kind" mimeType="$kind/mp4" startWithSAP="1"><Representation id="$track" $attrs><BaseURL>indexed-$track.mp4</BaseURL><SegmentBase indexRange="${init.length}-${init.length + index.lengthInBytes - 1}" indexRangeExact="true"><Initialization range="0-${init.length - 1}"/></SegmentBase></Representation></AdaptationSet>''',
    );
  }
  return (
    '''<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" type="static" mediaPresentationDuration="PT4S" minBufferTime="PT1S"><Period id="period0" start="PT0S" duration="PT4S"><BaseURL>period0/</BaseURL>${adaptations.join()}</Period></MPD>''',
    packed,
  );
}
