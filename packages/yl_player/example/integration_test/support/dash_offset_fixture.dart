import 'dart:typed_data';

/// Shift owned test fragments; this is never used by the player implementation.
Uint8List shiftDashFragment(
  Uint8List source,
  int delta, {
  required int timescale,
}) {
  if (source.isEmpty ||
      source.length > 2 * 1024 * 1024 ||
      delta < 0 ||
      timescale <= 0) {
    throw const FormatException('Invalid owned fragment bounds');
  }
  final copy = Uint8List.fromList(source);
  final data = ByteData.sublistView(copy);
  var boxes = 0, decodeTimes = 0, indexes = 0;
  void shift(int position, int width) {
    final value = width == 4
        ? data.getUint32(position)
        : data.getUint64(position);
    final limit = width == 4 ? 0xffffffff : 0x7fffffffffffffff;
    if (value < 0 || delta > limit - value) {
      throw const FormatException('Owned timestamp overflow');
    }
    if (width == 4) {
      data.setUint32(position, value + delta);
    } else {
      data.setUint64(position, value + delta);
    }
  }

  void walk(int start, int end, int depth) {
    if (depth > 4) throw const FormatException('Owned box nesting exceeded');
    while (start < end) {
      if (end - start < 8 || ++boxes > 64) {
        throw const FormatException('Invalid owned box header');
      }
      final size = data.getUint32(start);
      if (size < 8 || size > end - start) {
        throw const FormatException('Invalid owned box extent');
      }
      final type = String.fromCharCodes(copy.sublist(start + 4, start + 8));
      final body = start + 8;
      if (type == 'moof' || type == 'traf') {
        walk(body, start + size, depth + 1);
      } else if (type == 'tfdt' || type == 'sidx') {
        if (size < 12) throw const FormatException('Missing owned box version');
        final version = copy[body];
        if (version > 1) {
          throw const FormatException('Unsupported owned box version');
        }
        final width = version == 0 ? 4 : 8;
        if (type == 'tfdt') {
          if (size != 12 + width) {
            throw const FormatException('Invalid owned tfdt');
          }
          shift(body + 4, width);
          decodeTimes++;
        } else {
          if (size < 24 + 2 * width || data.getUint32(body + 8) != timescale) {
            throw const FormatException('Invalid owned sidx');
          }
          shift(body + 12, width);
          indexes++;
        }
      }
      start += size;
    }
  }

  walk(0, copy.length, 0);
  if (decodeTimes != 1 || indexes != 1) {
    throw const FormatException('Expected one owned tfdt and sidx');
  }
  return copy;
}

/// A deterministic shifted copy of the repository's two-Period AVC/AAC ladder.
/// Offset 10s in Period 0 and 30s in Period 1; program duration stays eight seconds.
final class DashOffsetFixture {
  DashOffsetFixture._(this.manifest, this.files);
  final String manifest;
  final Map<String, Uint8List> files;

  static DashOffsetFixture fromVariants(
    Map<String, Uint8List> originals, {
    bool segmentList = false,
  }) {
    final files = <String, Uint8List>{};
    final manifest = StringBuffer(
      '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT8S">',
    );
    for (final period in [0, 1]) {
      manifest.write(
        '<Period start="PT${period * 4}S" duration="PT4S"><BaseURL>period$period/</BaseURL>',
      );
      for (final kind in ['video', 'audio']) {
        manifest.write(
          '<AdaptationSet contentType="$kind" mimeType="$kind/mp4">',
        );
        final tracks = kind == 'audio' ? [2] : (period == 0 ? [0, 1] : [1, 0]);
        for (final track in tracks) {
          final audio = track == 2;
          final scale = audio ? 48000 : 12288;
          final offset = (period == 0 ? 10 : 30) * scale;
          final starts = audio
              ? [0, 47104, 95232, 143360, 191488]
              : [0, 12288, 24576, 36864];
          final durations = audio
              ? [47104, 48128, 48128, 48128, 512]
              : [12288, 12288, 12288, 12288];
          final init = '/period$period/init-$track.m4s';
          files[init] = Uint8List.fromList(originals[init]!);
          final timeline = StringBuffer('<SegmentTimeline>');
          final urls = <String>[];
          for (var index = 0; index < starts.length; index++) {
            final t = offset + starts[index];
            final name = 'chunk-$track-$t.m4s';
            final original =
                '/period$period/chunk-$track-${(index + 1).toString().padLeft(5, '0')}.m4s';
            files['/period$period/$name'] = shiftDashFragment(
              originals[original]!,
              offset,
              timescale: scale,
            );
            timeline.write('<S t="$t" d="${durations[index]}"/>');
            urls.add(name);
          }
          timeline.write('</SegmentTimeline>');
          final attributes = audio
              ? 'codecs="mp4a.40.2" bandwidth="64000" audioSamplingRate="48000"'
              : 'codecs="avc1.42c01e" bandwidth="${track == 0 ? 350000 : 700000}" width="${track == 0 ? 320 : 640}" height="${track == 0 ? 180 : 360}" frameRate="24/1"';
          manifest.write('<Representation id="p$period-$track" $attributes>');
          if (audio) {
            manifest.write(
              '<AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="1"/>',
            );
          }
          if (segmentList) {
            manifest.write(
              '<SegmentList timescale="$scale" presentationTimeOffset="$offset">$timeline<Initialization sourceURL="init-$track.m4s"/>',
            );
            for (final url in urls) {
              manifest.write('<SegmentURL media="$url"/>');
            }
            manifest.write('</SegmentList>');
          } else {
            manifest.write(
              '<SegmentTemplate timescale="$scale" presentationTimeOffset="$offset" initialization="init-$track.m4s" media="chunk-$track-\$Time\$.m4s">$timeline</SegmentTemplate>',
            );
          }
          manifest.write('</Representation>');
        }
        manifest.write('</AdaptationSet>');
      }
      manifest.write('</Period>');
    }
    manifest.write('</MPD>');
    return DashOffsetFixture._(manifest.toString(), Map.unmodifiable(files));
  }
}
