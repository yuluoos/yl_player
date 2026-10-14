part of 'dash_subtitles.dart';

final class _DashCell {
  _DashCell(this.period, this.track, this.segment, this.start, this.end);
  final DashSubtitlePeriod period;
  final DashSubtitleTrack track;
  final DashSubtitleSegment segment;
  final DashSubtitleTime start, end;
  String get key =>
      '${track.metadata.format.name}:${track.initialization?.key}:${segment.resource.key}';
}

/// Bounded selected-track window: two parsed segments and one initialization
/// resource. Repeated position ticks perform a binary search and no redundant
/// I/O. Seeking never resets the reader's logical-resource request histories.
final class DashSubtitleWindowLoader {
  DashSubtitleWindowLoader(this.catalog, this.reader) {
    for (final period in catalog.periods) {
      for (final track in period.tracks) {
        final cells = _cells.putIfAbsent(track.id, () => []);
        for (var i = 0; i < track.segments.length; i++) {
          final segment = track.segments[i];
          var start = period.start + (segment.start - track.offset);
          var end = start + segment.duration;
          if (i + 1 < track.segments.length) {
            final next =
                period.start + (track.segments[i + 1].start - track.offset);
            if (next < end) end = next;
          }
          if (start < period.start) start = period.start;
          if (end > period.end) end = period.end;
          if (end > start) {
            cells.add(_DashCell(period, track, segment, start, end));
          }
        }
      }
    }
  }
  final DashSubtitleCatalog catalog;
  final DashSubtitleReader reader;
  final _cells = <String, List<_DashCell>>{};
  final _cache = <String, SubtitleDocument>{};
  String? _initKey;
  DashSubtitleReply? _initialization;
  int _index(String id, Duration position) {
    final cells = _cells[id] ?? _dashBad();
    final at = DashSubtitleTime.of(position.inMicroseconds, 1000000);
    var low = 0, high = cells.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (cells[mid].end <= at) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  String windowKey(String id, Duration position) =>
      '$id:${_index(id, position)}';
  void clear() {
    _cache.clear();
    _initKey = null;
    _initialization = null;
  }

  Future<SubtitleDocument> load(
    String id,
    Duration position,
    SubtitleCancellation token, {
    int maxInputBytes = 4 * 1024 * 1024,
    int maxCues = 10000,
  }) async {
    if (maxInputBytes < 1 ||
        maxInputBytes > 4 * 1024 * 1024 ||
        maxCues < 1 ||
        maxCues > 10000) {
      _dashLimit();
    }
    final cells = _cells[id] ?? _dashBad(), index = _index(id, position);
    final result = <SubtitleDocument>[];
    var remaining = maxInputBytes;
    for (var i = index; i < cells.length && i < index + 2; i++) {
      token.check();
      final cell = cells[i];
      var doc = _cache.remove(cell.key);
      if (doc == null) {
        if (remaining < 1) _dashLimit();
        doc = await _read(cell, token, remaining);
      }
      if (doc.inputBytes > remaining) _dashLimit();
      token.check();
      _cache[cell.key] = doc;
      while (_cache.length > 2 ||
          _cache.values.fold<int>(0, (n, d) => n + d.inputBytes) >
              maxInputBytes) {
        _cache.remove(_cache.keys.first);
      }
      remaining -= doc.inputBytes;
      final delta = cell.period.start - cell.track.offset;
      result.add(
        doc.mappedWindow(
          mapStart: (time) => Duration(
            microseconds:
                (DashSubtitleTime.of(time.inMicroseconds, 1000000) + delta)
                    .microseconds(ceil: true),
          ),
          mapEnd: (time) => Duration(
            microseconds:
                (DashSubtitleTime.of(time.inMicroseconds, 1000000) + delta)
                    .microseconds(),
          ),
          start: Duration(microseconds: cell.start.microseconds(ceil: true)),
          end: Duration(microseconds: cell.end.microseconds()),
        ),
      );
    }
    token.check();
    return SubtitleDocument.combine(
      result,
      limits: SubtitleLimits(maxInputBytes: maxInputBytes, maxCues: maxCues),
    );
  }

  Future<SubtitleDocument> _read(
    _DashCell cell,
    SubtitleCancellation token,
    int maxBytes,
  ) async {
    final track = cell.track;
    final data = await reader.read(cell.segment.resource, token, maxBytes);
    token.check();
    if (!track.fragmented) {
      return SubtitleDocument.parse(
        data.bytes,
        limits: SubtitleLimits(maxInputBytes: maxBytes),
        format: track.metadata.format == YlSubtitleFormat.webvtt
            ? SubtitleFormat.webvtt
            : SubtitleFormat.ttml,
      );
    }
    DashSubtitleReply? init;
    // A complete MP4 subtitle file owns its own moov; fragmented resources use
    // the declared initialization resource. No alternate subtitle parser.
    final complete =
        data.sourceOffset == 0 &&
        data.bytes.length >= 8 &&
        String.fromCharCodes(data.bytes.sublist(4, 8)) == 'ftyp';
    if (track.initialization case final resource? when !complete) {
      if (_initKey != resource.key) {
        _initialization = null;
        _initKey = null;
        final allowance = maxBytes - data.bytes.length;
        if (allowance < 1) _dashLimit();
        final value = await reader.read(
          resource,
          token,
          allowance < 1024 * 1024 ? allowance : 1024 * 1024,
        );
        token.check();
        _initialization = value;
        _initKey = resource.key;
      }
      init = _initialization;
    }
    final inputBytes = data.bytes.length + (init?.bytes.length ?? 0);
    if (inputBytes > maxBytes) _dashLimit();
    final input = _DashIsoInput(init, data);
    final entries = await Mp4Subtitles(input.length, input.read, token).parse();
    token.check();
    if (entries.length != 1 ||
        entries.single.track.format != track.metadata.format) {
      _dashUnsupported();
    }
    final entry = entries.single;
    return SubtitleDocument.fromEmbeddedPackets(
      entry.packets,
      format: track.metadata.format == YlSubtitleFormat.webvtt
          ? SubtitleFormat.webvtt
          : SubtitleFormat.ttml,
      sourceBytes: inputBytes,
      limits: SubtitleLimits(maxInputBytes: maxBytes),
    );
  }
}

/// Sparse original byte coordinates for Range fragments with absolute tfhd
/// offsets. ISO free headers skip holes; no file or hole-sized allocation.
final class _DashIsoInput {
  _DashIsoInput(DashSubtitleReply? init, DashSubtitleReply media) {
    if (init != null) _append(init.sourceOffset, init.bytes);
    final start = media.sourceOffset == 0 ? length : media.sourceOffset;
    _append(start, media.bytes);
  }
  final _parts = <(int, List<int>)>[];
  int length = 0;
  void _append(int start, List<int> bytes) {
    if (start < length || start > 0x1fffffffffffff - bytes.length) {
      _dashUnsupported();
    }
    final gap = start - length;
    if (gap > 0) {
      if (gap < 8) _dashUnsupported();
      List<int> integer(int n, int size) => [
        for (var i = size - 1; i >= 0; i--) (n >> (i * 8)) & 255,
      ];
      _parts.add((
        length,
        gap <= 0xffffffff
            ? [...integer(gap, 4), ...ascii.encode('free')]
            : [...integer(1, 4), ...ascii.encode('free'), ...integer(gap, 8)],
      ));
    }
    _parts.add((start, bytes));
    length = start + bytes.length;
  }

  Future<List<int>> read(int start, int count) async {
    if (start < 0 ||
        count < 0 ||
        count > 256 * 1024 ||
        start > length ||
        count > length - start) {
      _dashLimit();
    }
    final bytes = List<int>.filled(count, 0);
    for (final (offset, data) in _parts) {
      final from = start > offset ? start : offset;
      final stop = start + count < offset + data.length
          ? start + count
          : offset + data.length;
      if (stop > from) {
        bytes.setRange(from - start, stop - start, data, from - offset);
      }
    }
    return bytes;
  }
}
