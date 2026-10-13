part of 'subtitle_document.dart';

/// Raw Matroska PGS segments without SUP magic/PTS/DTS framing.
final class EmbeddedPgsPacket {
  EmbeddedPgsPacket(this.start, List<int> bytes, {this.end})
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final Duration start;
  final Duration? end;
  final Uint8List bytes;
  @override
  String toString() => 'EmbeddedPgsPacket(payload: <redacted>)';
}

/// Immutable, premultiplied-alpha RGBA pixels. Only the active overlay creates
/// engine images; catalog parsing never creates a GPU/native image handle.
/// Shared with DVD VobSub; the historical internal type name is retained.
final class PgsBitmap {
  PgsBitmap._(
    this.x,
    this.y,
    this.width,
    this.height,
    this.forced,
    Uint8List rgba,
  ) : rgba = rgba.asUnmodifiableView();
  final int x, y, width, height;
  final bool forced;
  final Uint8List rgba;
}

final class PgsFrame {
  PgsFrame._(this.width, this.height, List<PgsBitmap> bitmaps)
    : bitmaps = List.unmodifiable(bitmaps);
  final int width, height;
  final List<PgsBitmap> bitmaps;
  int get byteLength => bitmaps.fold(0, (n, b) => n + b.rgba.length);
}

final class _PgsReader {
  _PgsReader(this.bytes);
  final List<int> bytes;
  var offset = 0;
  int get left => bytes.length - offset;
  int byte() {
    if (left < 1) _malformed();
    return bytes[offset++];
  }

  int word() => byte() * 256 + byte();
  int triple() => byte() * 65536 + word();
  int long() => word() * 65536 + word();
  List<int> take(int n) {
    if (n < 0 || n > left) _malformed();
    final result = bytes.sublist(offset, offset + n);
    offset += n;
    return result;
  }

  void done() {
    if (left != 0) _malformed();
  }
}

final class _PgsObject {
  _PgsObject(this.version, this.width, this.height, this.length);
  final int version, width, height, length;
  final data = BytesBuilder(copy: false);
  Uint8List? pixels;
}

final class _PgsBox {
  const _PgsBox(this.x, this.y, this.w, this.h);
  final int x, y, w, h;
}

final class _PgsRef {
  const _PgsRef(this.id, this.window, this.x, this.y, this.forced, this.crop);
  final int id, window, x, y;
  final bool forced;
  final _PgsBox? crop;
}

SubtitleDocument _parsePgs(List<int> bytes, SubtitleLimits limits) =>
    _PgsParser(limits).parse(bytes);

final class _PgsParser {
  _PgsParser(this.limits);
  final SubtitleLimits limits;
  final objects = <int, _PgsObject>{};
  final palettes = <int, List<int>>{};
  final windows = <int, _PgsBox>{};
  final cues = <SubtitleCue>[];
  var width = 0, height = 0, paletteId = 0;
  var indexedBytes = 0, rgbaBytes = 0, segments = 0, displays = 0;
  var inDisplay = false, paletteUpdate = false, hasWindow = false;
  var references = <_PgsRef>[], plane = <_PgsRef>[];
  var pts = Duration.zero, lastPts = Duration.zero;
  int? rawPts;
  var rollover = 0;
  PgsFrame? previous;
  Duration? displayEnd, previousEnd;
  SubtitleDocument parse(List<int> bytes) {
    final r = _PgsReader(bytes);
    if (r.left == 0) _malformed();
    while (r.left > 0) {
      if (++segments > 50000) _limit();
      if (r.word() != 0x5047) _malformed();
      final timestamp = r.long();
      r.long(); // DTS is not presentation time.
      final type = r.byte(), length = r.word();
      final body = _PgsReader(r.take(length));
      segment(type, body, timestamp: timestamp);
      body.done();
    }
    if (inDisplay) _malformed();
    append(const Duration(days: 7));
    return SubtitleDocument._finish(cues, bytes.length, limits);
  }

  SubtitleDocument parseEmbedded(List<EmbeddedPgsPacket> packets) {
    if (packets.length > 50000) _limit();
    var inputBytes = 0;
    for (final packet in packets) {
      inputBytes += packet.bytes.length;
      if (inputBytes > limits.maxInputBytes ||
          packet.bytes.length > 256 * 1024) {
        _limit();
      }
      if (packet.start.isNegative ||
          packet.start >= const Duration(days: 7) ||
          (packet.end != null &&
              (packet.end! <= packet.start ||
                  packet.end! > const Duration(days: 7)))) {
        _malformed();
      }
      final r = _PgsReader(packet.bytes);
      if (r.left == 0) _malformed();
      while (r.left > 0) {
        if (++segments > 50000) _limit();
        final type = r.byte(), length = r.word();
        final body = _PgsReader(r.take(length));
        if (type == 0x16) {
          displayEnd = packet.end;
        } else if (packet.end != null &&
            (displayEnd == null || packet.end! < displayEnd!)) {
          displayEnd = packet.end;
        }
        segment(type, body, time: packet.start);
        body.done();
      }
    }
    if (inDisplay) _malformed();
    append(const Duration(days: 7));
    return SubtitleDocument._finish(cues, inputBytes, limits);
  }

  void segment(int type, _PgsReader body, {int timestamp = 0, Duration? time}) {
    if (type == 0x16) {
      if (inDisplay) _malformed();
      presentation(body, timestamp, time: time);
    } else {
      if (!inDisplay) _malformed();
      switch (type) {
        case 0x14:
          palette(body);
        case 0x15:
          if (paletteUpdate) _unsupported();
          object(body);
        case 0x17:
          if (paletteUpdate) _unsupported();
          window(body);
        case 0x80:
          if (displayEnd != null && displayEnd! <= pts) _malformed();
          finish();
        default:
          _unsupported();
      }
    }
  }

  void presentation(_PgsReader r, int timestamp, {Duration? time}) {
    if (++displays > limits.maxCues) _limit();
    if (time != null) {
      if (time < lastPts) _malformed();
      pts = time;
    } else {
      if (rawPts != null && timestamp < rawPts!) {
        if (rawPts! - timestamp <= 0x80000000) _malformed();
        rollover += 0x100000000;
      }
      rawPts = timestamp;
      final ticks = timestamp + rollover;
      if (ticks >= 7 * 24 * 60 * 60 * 90000) _limit();
      pts = Duration(microseconds: ticks * 1000000 ~/ 90000);
    }
    final w = r.word(), h = r.word();
    r.byte();
    r.word();
    dimensions(w, h);
    final state = r.byte(), update = r.byte();
    if (![0, 0x40, 0x80].contains(state) || ![0, 0x80].contains(update)) {
      _unsupported();
    }
    if (state == 0 && width != 0 && (w != width || h != height)) _unsupported();
    if (state != 0) {
      objects.clear();
      palettes.clear();
      windows.clear();
      plane = [];
      indexedBytes = 0;
    }
    width = w;
    height = h;
    paletteId = r.byte();
    paletteUpdate = update == 0x80;
    if (paletteUpdate && (state != 0 || plane.isEmpty)) _malformed();
    final count = r.byte();
    if (count > 2) _limit();
    references = [];
    for (var i = 0; i < count; i++) {
      final id = r.word(),
          window = r.byte(),
          flags = r.byte(),
          x = r.word(),
          y = r.word();
      if (flags & 0x3f != 0) _unsupported();
      final crop = flags & 0x80 == 0
          ? null
          : _PgsBox(r.word(), r.word(), r.word(), r.word());
      references.add(_PgsRef(id, window, x, y, flags & 0x40 != 0, crop));
    }
    // Palette-only display sets recolor the existing plane; PCS references do
    // not replace it (including the conventional single placeholder object).
    hasWindow = false;
    inDisplay = true;
  }

  void dimensions(int w, int h) {
    if (w == 0 || h == 0) _malformed();
    if (w > 8192 || h > 8192) _limit();
  }

  void window(_PgsReader r) {
    if (hasWindow) _malformed();
    final count = r.byte();
    if (count > 2) _limit();
    windows.clear();
    for (var i = 0; i < count; i++) {
      final id = r.byte(),
          x = r.word(),
          y = r.word(),
          w = r.word(),
          h = r.word();
      if (windows.containsKey(id) ||
          w == 0 ||
          h == 0 ||
          x + w > width ||
          y + h > height) {
        _malformed();
      }
      windows[id] = _PgsBox(x, y, w, h);
    }
    hasWindow = true;
  }

  void palette(_PgsReader r) {
    final id = r.byte();
    r.byte();
    if (r.left % 5 != 0) _malformed();
    if (!palettes.containsKey(id) && palettes.length >= 8) _limit();
    final colors = [...?palettes[id]];
    if (colors.isEmpty) colors.addAll(List.filled(256, 0));
    final seen = <int>{};
    while (r.left > 0) {
      final entry = r.byte(),
          y = r.byte(),
          cr = r.byte(),
          cb = r.byte(),
          alpha = r.byte();
      if (!seen.add(entry)) _malformed();
      // SUP has no color matrix metadata: use conventional SD 601 / HD 709
      // limited-range conversion, retaining straight alpha (not text styling).
      final luma = (y - 16) * 255 / 219, u = cb - 128, v = cr - 128;
      int channel(double value) => value.round().clamp(0, 255);
      final hd = height > 576;
      final red = channel(luma + (hd ? 1.792741 : 1.596027) * v);
      final green = channel(
        luma - (hd ? 0.213249 : 0.391762) * u - (hd ? 0.532909 : 0.812968) * v,
      );
      final blue = channel(luma + (hd ? 2.112402 : 2.017232) * u);
      colors[entry] = (red << 24) | (green << 16) | (blue << 8) | alpha;
    }
    palettes[id] = colors;
  }

  void object(_PgsReader r) {
    final id = r.word(), version = r.byte(), flags = r.byte();
    if (flags & 0x3f != 0) _unsupported();
    if (flags & 0x80 != 0) {
      if (objects[id] case final old?) {
        if (old.pixels == null) _malformed();
        indexedBytes -= old.pixels!.length;
      } else if (objects.length >= 64) {
        _limit();
      }
      final length = r.triple() - 4, w = r.word(), h = r.word();
      dimensions(w, h);
      if (w > width || h > height || length < 1) _malformed();
      if (w * h > 4 * 1024 * 1024 ||
          length > 4 * 1024 * 1024 ||
          indexedBytes + w * h > 16 * 1024 * 1024) {
        _limit();
      }
      objects[id] = _PgsObject(version, w, h, length);
    }
    final obj = objects[id];
    if (obj == null || obj.version != version || obj.pixels != null) {
      _malformed();
    }
    if (r.left == 0 || obj.data.length + r.left > obj.length) _malformed();
    obj.data.add(r.take(r.left));
    if (flags & 0x40 != 0) {
      if (obj.data.length != obj.length) _malformed();
      if (indexedBytes + obj.width * obj.height > 16 * 1024 * 1024) _limit();
      obj.pixels = rle(obj.data.takeBytes(), obj.width, obj.height);
      indexedBytes += obj.pixels!.length;
    } else if (obj.data.length == obj.length) {
      _malformed();
    }
  }

  Uint8List rle(Uint8List encoded, int w, int h) {
    final r = _PgsReader(encoded), pixels = Uint8List(w * h);
    var x = 0, y = 0;
    while (r.left > 0) {
      if (y >= h) _malformed();
      var color = r.byte(), count = 1;
      if (color == 0) {
        final flags = r.byte();
        if (flags == 0) {
          if (x != w) _malformed();
          x = 0;
          y++;
          continue;
        }
        count = flags & 0x3f;
        if (flags & 0x40 != 0) count = count * 256 + r.byte();
        color = flags & 0x80 != 0 ? r.byte() : 0;
        if (count == 0) _malformed();
      }
      if (x + count > w) _malformed();
      pixels.fillRange(y * w + x, y * w + x + count, color);
      x += count;
    }
    if (y != h || x != 0) _malformed();
    return pixels;
  }

  void finish() {
    if (objects.values.any((o) => o.pixels == null)) _malformed();
    if (!paletteUpdate) {
      // This slice supports explicit plane redraws and clear events, not
      // ambiguous cache-only display sets that silently change placement.
      if (references.isNotEmpty && !hasWindow) _unsupported();
      plane = references;
    }
    final colors = palettes[paletteId];
    if (plane.isNotEmpty && colors == null) _malformed();
    final bitmaps = <PgsBitmap>[];
    for (final ref in plane) {
      final obj = objects[ref.id], win = windows[ref.window];
      if (obj == null || win == null) _malformed();
      final crop = ref.crop ?? _PgsBox(0, 0, obj.width, obj.height);
      if (crop.w == 0 ||
          crop.h == 0 ||
          crop.x + crop.w > obj.width ||
          crop.y + crop.h > obj.height) {
        _malformed();
      }
      if (ref.x >= width || ref.y >= height) _malformed();
      // Cropped object source is placed at PCS (x,y), then clipped by its
      // window and the presentation canvas. Allocate only visible pixels.
      final left = math.max(ref.x, win.x), top = math.max(ref.y, win.y);
      final right = math.min(ref.x + crop.w, math.min(win.x + win.w, width));
      final bottom = math.min(ref.y + crop.h, math.min(win.y + win.h, height));
      if (right <= left || bottom <= top) continue;
      final w = right - left, h = bottom - top, size = w * h * 4;
      if (rgbaBytes + size > limits.maxPgsBitmapBytes) _limit();
      rgbaBytes += size;
      final rgba = Uint8List(size);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final index =
              obj.pixels![(crop.y + top - ref.y + y) * obj.width +
                  crop.x +
                  left -
                  ref.x +
                  x];
          final color = colors![index], p = (y * w + x) * 4;
          final alpha = color & 255;
          rgba[p] = ((color >> 24) * alpha + 127) ~/ 255;
          rgba[p + 1] = (((color >> 16) & 255) * alpha + 127) ~/ 255;
          rgba[p + 2] = (((color >> 8) & 255) * alpha + 127) ~/ 255;
          rgba[p + 3] = alpha;
        }
      }
      bitmaps.add(PgsBitmap._(left, top, w, h, ref.forced, rgba));
    }
    append(pts);
    previous = bitmaps.isEmpty ? null : PgsFrame._(width, height, bitmaps);
    previousEnd = displayEnd;
    lastPts = pts;
    inDisplay = false;
  }

  void append(Duration end) {
    if (previousEnd != null && previousEnd! < end) end = previousEnd!;
    if (previous == null || end <= lastPts) return;
    if (cues.length >= limits.maxCues) _limit();
    cues.add(
      SubtitleCue._(
        ordinal: cues.length,
        identifier: null,
        start: lastPts,
        end: end,
        payload: '',
        pgs: previous,
      ),
    );
  }
}
