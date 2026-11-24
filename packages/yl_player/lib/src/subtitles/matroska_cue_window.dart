part of 'matroska_subtitles.dart';

typedef _CueLocation = ({int ticks, int duration, int cluster, int relative});

extension on MatroskaSubtitles {
  Future<int?> _cueOffset(_Element head, _Element segment) async {
    for (final seek in await _children(head)) {
      if (seek.id != 0x4dbb) continue;
      final fields = await _fields(seek);
      final id = fields[0x53ab], position = fields[0x53ac];
      if (id == null || position == null) _bad();
      if (await _uint(id) == 0x1c53bb6b) {
        final offset = segment.start + await _uint(position);
        if (offset >= segment.end) _bad();
        return offset;
      }
    }
    return null;
  }

  Future<_MatroskaCueWindow> _readCueIndex(
    int offset,
    _Element segment,
    MatroskaWindowRead open,
  ) async {
    final cues = await _element(offset, segment.end);
    if (cues.id != 0x1c53bb6b) _bad();
    if (cues.size > 4 * 1024 * 1024) _limit();
    final bytes = Uint8List(cues.size);
    for (var i = 0; i < bytes.length;) {
      final count = (bytes.length - i).clamp(0, 256 * 1024);
      bytes.setRange(i, i + count, await _bytes(cues.start + i, count));
      i += count;
    }
    // Parse EBML fields from memory. An index can contain tens of thousands
    // of small integers; they must not become individual network requests.
    final index = MatroskaSubtitles(
      bytes.length,
      (p, n) async => Uint8List.sublistView(bytes, p, p + n),
      token,
    );
    final locations = <int, List<_CueLocation>>{};
    var count = 0;
    for (var pos = 0; pos < bytes.length;) {
      final point = await index._element(pos, bytes.length);
      pos = point.end;
      if (point.id != 0xbb) continue;
      final children = await index._children(point, limit: 256);
      final times = children.where((c) => c.id == 0xb3);
      if (times.length != 1) _bad();
      final ticks = await index._uint(times.single);
      final maxTicks = 604800000000000 ~/ _scale;
      if (ticks > maxTicks) _limit();
      for (final child in children) {
        if (child.id != 0xb7) continue;
        final fields = await index._fields(child);
        final numberField = fields[0xf7];
        if (numberField == null) _bad();
        final number = await index._uint(numberField);
        if (!_tracks.containsKey(number)) continue;
        final cluster = fields[0xf1],
            relative = fields[0xf0],
            duration = fields[0xb2];
        if (cluster == null || relative == null || duration == null) {
          _unsupported();
        }
        final d = await index._uint(duration);
        final c = segment.start + await index._uint(cluster);
        final r = await index._uint(relative);
        if (d <= 0 ||
            d > maxTicks - ticks ||
            c >= segment.end ||
            r >= segment.end - c) {
          _bad();
        }
        if (++count > 128000) _limit();
        final entries = locations.putIfAbsent(number, () => []);
        if (entries.isNotEmpty && ticks < entries.last.ticks) _bad();
        entries.add((ticks: ticks, duration: d, cluster: c, relative: r));
      }
    }
    if (_tracks.keys.any((n) => !locations.containsKey(n))) _unsupported();
    return _MatroskaCueWindow(length, _scale, _tracks, locations, open);
  }
}

final class _MatroskaCueWindow implements SubtitleWindowLoader {
  _MatroskaCueWindow(
    this.length,
    this.scale,
    Map<int, _Track> tracks,
    this.locations,
    this.open,
  ) : numbers = {for (final e in tracks.entries) e.value.track.id: e.key},
      metadata = tracks;
  final int length, scale;
  final Map<String, int> numbers;
  final Map<int, _Track> metadata;
  final Map<int, List<_CueLocation>> locations;
  final MatroskaWindowRead open;
  @override
  late final tracks = List<YlSubtitleTrack>.unmodifiable(
    metadata.values.map((v) => v.track),
  );

  static const _windowUs = 8 * 1000000;
  int _bucket(Duration position) => position.inMicroseconds ~/ _windowUs;
  @override
  String windowKey(String id, Duration position) => '$id:${_bucket(position)}';

  @override
  void clear() {} // Windows own their HTTP reader; only immutable metadata survives.

  @override
  Future<SubtitleDocument> load(
    String id,
    Duration position,
    SubtitleCancellation token, {
    required int maxInputBytes,
    required int maxCues,
  }) async {
    final number = numbers[id];
    final meta = metadata[number];
    if (number == null || meta == null) {
      throw subtitleFailure(YlFailureCodes.sourceInvalid);
    }
    final parser = MatroskaSubtitles(length, open(token), token)
      .._scale = scale;
    final selected = _Track(meta.track, null, meta.defaultDuration, meta.delay);
    parser._numbers.add(number);
    parser._tracks[number] = selected;
    final start = _bucket(position) * _windowUs;
    final end = start + 2 * _windowUs;
    final clocks = <int, (int, int, int)>{};
    for (final cue in locations[number]!) {
      final startNs = cue.ticks * scale - meta.delay;
      if (startNs < 0) parser._bad();
      if (startNs ~/ 1000 >= end) break;
      if ((startNs + cue.duration * scale) ~/ 1000 <= start) continue;
      if (selected.packets.length >= maxCues) parser._limit();
      var clock = clocks[cue.cluster];
      if (clock == null) {
        final cluster = await parser._element(cue.cluster, length);
        if (cluster.id != 0x1f43b675) parser._bad();
        var offset = cluster.start;
        for (var i = 0; i < 128 && offset < cluster.end; i++) {
          final child = await parser._element(offset, cluster.end);
          if (child.id == 0xe7) {
            clock = (cluster.start, cluster.end, await parser._uint(child));
            break;
          }
          offset = child.end;
        }
        if (clock == null) parser._unsupported();
        clocks[cue.cluster] = clock;
      }
      if (cue.relative >= clock.$2 - clock.$1) parser._bad();
      final group = await parser._element(clock.$1 + cue.relative, clock.$2);
      if (group.id != 0xa0) parser._unsupported();
      final f = await parser._fields(group, blockGroup: true);
      final block = f[0xa1], duration = f[0x9b];
      if (block == null ||
          duration == null ||
          await parser._uint(duration) != cue.duration) {
        parser._bad();
      }
      await parser._block(
        block,
        clock.$3,
        cue.duration,
        [0xa4, 0x75a2, 0x8e, 0xfd].any(f.containsKey) ||
            (f[0xfa] != null && await parser._uint(f[0xfa]!) != 0),
        additions: f[0x75a1],
      );
      if (selected.packets.last.start.inMicroseconds != startNs ~/ 1000) {
        parser._bad();
      }
      if (parser._payloadBytes > maxInputBytes) parser._limit();
    }
    return SubtitleDocument.fromEmbeddedPackets(
      selected.packets,
      format: SubtitleFormat.srt,
    );
  }
}
