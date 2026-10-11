part of 'mp4_subtitles.dart';

typedef _Mp4Edit = ({int delay, int delayTicks, int mediaStart, int end});

final class _Mp4TrackSamples {
  _Mp4TrackSamples(
    this.track,
    this.descriptions,
    this.scale,
    this.movieScale,
    this.edit,
  );
  final YlSubtitleTrack track;
  final List<_Mp4SubtitleEntry> descriptions;
  final int scale, movieScale;
  final _Mp4Edit edit;
  final packets = <EmbeddedSubtitlePacket>[];
  var sourceBytes = 0, ordinal = 0;
  int? decodeEnd;
  EmbeddedSubtitleData data() => EmbeddedSubtitleData(
    track,
    null,
    List.unmodifiable(packets),
    sourceBytes: sourceBytes,
  );
}

final class _Trex {
  const _Trex(this.description, this.duration, this.size, this.flags);
  final int description, duration, size, flags;
}

extension _FragmentReader on Mp4Subtitles {
  Future<void> _readFragments(_Box mvex, List<_Box> fragments) async {
    final defaults = <int, _Trex>{};
    final config = await _children(mvex.start, mvex.end);
    for (final b in config) {
      if (b.type == 'mehd') {
        final bytes = await _body(b, min: 8);
        _full(bytes, versions: [0, 1]);
        if (bytes.length != (bytes[0] == 0 ? 8 : 12)) _bad();
        continue;
      }
      if (b.type != 'trex') _unsupported();
      final bytes = await _body(b, min: 24);
      _full(bytes);
      if (bytes.length != 24) _bad();
      final id = _u(bytes, 4), description = _u(bytes, 8);
      if (!_ids.contains(id) || description == 0 || defaults.containsKey(id)) {
        _bad();
      }
      final track = _fragmentTracks[id];
      if (track != null && description > track.descriptions.length) _bad();
      defaults[id] = _Trex(
        description,
        _u(bytes, 12),
        _u(bytes, 16),
        _u(bytes, 20),
      );
    }
    if (defaults.isEmpty) _unsupported();
    if (_fragmentTracks.keys.any((id) => !defaults.containsKey(id))) _bad();
    var sequence = -1;
    final extents = <(int, int)>[];
    for (final moof in fragments) {
      token.check();
      final boxes = await _children(moof.start, moof.end);
      if (boxes.any(
        (b) => !['mfhd', 'traf', 'free', 'skip'].contains(b.type),
      )) {
        _unsupported();
      }
      final header = await _body(_one(boxes, 'mfhd', required: true)!, min: 8);
      _full(header);
      if (header.length != 8) _bad();
      final seq = _u(header, 4);
      if (seq <= sequence) _bad();
      sequence = seq;
      final trafs = boxes.where((b) => b.type == 'traf').toList();
      if (trafs.isEmpty) _bad();
      for (var i = 0; i < trafs.length; i++) {
        final traf = trafs[i];
        final children = await _children(traf.start, traf.end);
        final h = await _body(_one(children, 'tfhd', required: true)!, min: 8);
        if (h[0] != 0) _unsupported();
        final f = _u(h, 1, 3), id = _u(h, 4);
        if (f & ~0x03003b != 0) _unsupported();
        if (f & 1 != 0 && f & 0x020000 != 0) _bad();
        final inherited = defaults[id];
        if (!_ids.contains(id) || inherited == null) _bad();
        var at = 8;
        int next([int width = 4]) {
          final v = _u(h, at, width);
          at += width;
          return v;
        }

        final base = f & 1 != 0 ? next(8) : moof.offset;
        final description = f & 2 != 0 ? next() : inherited.description;
        final duration = f & 8 != 0 ? next() : inherited.duration;
        final size = f & 16 != 0 ? next() : inherited.size;
        final sampleFlags = f & 32 != 0 ? next() : inherited.flags;
        if (at != h.length) _bad();
        final track = _fragmentTracks[id];
        // Audio/video samples are outside the subtitle reader. A later subtitle
        // traf must carry an explicit/moof base; never infer it from skipped data.
        if (track == null) continue;
        if (f & 0x020001 == 0 && i != 0) _unsupported();
        if (children.any(
          (b) => !['tfhd', 'tfdt', 'trun', 'free', 'skip'].contains(b.type),
        )) {
          _unsupported();
        }
        if (description < 1 || description > track.descriptions.length) _bad();
        final timeBox = _one(children, 'tfdt');
        if (timeBox == null) _unsupported();
        final tb = await _body(timeBox, min: 8);
        _full(tb, versions: [0, 1]);
        if (tb.length != (tb[0] == 0 ? 8 : 12)) _bad();
        var dts = _u(tb, 4, tb[0] == 0 ? 4 : 8);
        if (dts > track.scale * 604800) _limit();
        if (track.decodeEnd != null && dts < track.decodeEnd!) _bad();
        final runs = children.where((b) => b.type == 'trun').toList();
        if (runs.isEmpty && f & 0x010000 == 0) _bad();
        var pos = base;
        for (final run in runs) {
          final b = await _body(run, min: 8);
          if (![0, 1].contains(b[0])) _unsupported();
          final flags = _u(b, 1, 3), count = _u(b, 4);
          if (flags & ~0x000f05 != 0) _unsupported();
          if (flags & 4 != 0 && flags & 0x400 != 0) _bad();
          _samples += count;
          if (_samples > 20000) _limit();
          if (f & 0x010000 != 0 && count != 0) _bad();
          var cursor = 8;
          int field([bool signed = false]) {
            final v = signed ? _signed(b, cursor, 4) : _u(b, cursor);
            cursor += 4;
            return v;
          }

          if (flags & 1 != 0) pos = base + field(true);
          final firstFlags = flags & 4 != 0 ? field() : sampleFlags;
          final words = [
            0x100,
            0x200,
            0x400,
            0x800,
          ].where((bit) => flags & bit != 0).length;
          if (b.length != cursor + count * words * 4) _bad();
          for (var k = 0; k < count; k++) {
            final delta = flags & 0x100 != 0 ? field() : duration;
            final length = flags & 0x200 != 0 ? field() : size;
            final sf = flags & 0x400 != 0
                ? field()
                : k == 0
                ? firstFlags
                : sampleFlags;
            final cto = flags & 0x800 != 0 ? field(b[0] == 1) : 0;
            // Reserved sample flags/field values are not valid dependency metadata.
            if (sf & 0xf0000000 != 0 ||
                [4, 6, 8].any((shift) => (sf >> (shift + 16)) & 3 == 3)) {
              _bad();
            }
            await _appendSample(
              track,
              track.descriptions[description - 1],
              pos,
              length,
              dts + cto,
              delta,
            );
            extents.add((pos, pos + length));
            pos += length;
            dts += delta;
            if (dts > track.scale * 604800) _limit();
          }
        }
        track.decodeEnd = dts;
      }
    }
    extents.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < extents.length; i++) {
      if (extents[i].$1 < extents[i - 1].$2) _bad();
    }
  }
}
