import 'dart:typed_data';

import 'udf.dart';

/// The first enabled DVD audio track is selected in PGC logical-track order.
/// Private-stream AC-3 carries a four-byte DVD header outside the AC-3 data.
typedef DvdAudio = ({int stream, bool ac3});

final class DvdTransport {
  DvdTransport(this.audio, this.clockOffset, {required bool mpeg1}) {
    _tables(mpeg1);
  }
  final DvdAudio? audio;
  final int clockOffset;
  final _bytes = BytesBuilder(copy: false);
  final _cc = <int, int>{};
  static const _video = 256, _audio = 257, _pmt = 4096;
  int? _lastClock;
  bool _videoSeen = false;

  void _tables(bool mpeg1) {
    void table(int pid, List<int> section) {
      var crc = 0xffffffff;
      for (final byte in section) {
        crc ^= byte << 24;
        for (var i = 0; i < 8; i++) {
          crc =
              ((crc << 1) ^ (crc & 0x80000000 == 0 ? 0 : 0x04c11db7)) &
              0xffffffff;
        }
      }
      final packet = Uint8List(188)..fillRange(0, 188, 255);
      packet.setAll(0, [
        0x47,
        0x40 | (pid >> 8),
        pid & 255,
        0x30,
        1, 0x80, // Reset the continuity counter at this independent segment.
        0,
        ...section,
        crc >> 24,
        (crc >> 16) & 255,
        (crc >> 8) & 255,
        crc & 255,
      ]);
      _bytes.add(packet);
    }

    table(0, [
      0,
      0xb0,
      13,
      0,
      1,
      0xc1,
      0,
      0,
      0,
      1,
      0xe0 | (_pmt >> 8),
      _pmt & 255,
    ]);
    final tracks = <int>[mpeg1 ? 1 : 2, 0xe1, 0, 0xf0, 0];
    if (audio case final a?) {
      tracks.addAll([a.ac3 ? 0x81 : 0x03, 0xe1, 1, 0xf0, 0]);
    }
    table(_pmt, [
      2,
      0xb0,
      13 + tracks.length,
      0,
      1,
      0xc1,
      0,
      0,
      0xe1,
      0,
      0xf0,
      0,
      ...tracks,
    ]);
  }

  void _clock(Uint8List b, int i) {
    final raw =
        ((b[i + 4] & 56) << 27) |
        ((b[i + 4] & 3) << 28) |
        (b[i + 5] << 20) |
        ((b[i + 6] & 248) << 12) |
        ((b[i + 6] & 3) << 13) |
        (b[i + 7] << 5) |
        (b[i + 8] >> 3);
    final base = (raw + clockOffset) & 0x1ffffffff;
    if (_lastClock != null && ((base - _lastClock!) & 0x1ffffffff) < 3600) {
      return;
    }
    final ext = ((b[i + 8] & 3) << 7) | (b[i + 9] >> 1);
    final cc = ((_cc[_video] ?? 0) - 1) & 15;
    final packet = Uint8List(188)..fillRange(0, 188, 255);
    packet.setAll(0, [
      0x47,
      1,
      0,
      0x20 | cc,
      183,
      _lastClock == null ? 0x90 : 0x10,
      base >> 25,
      (base >> 17) & 255,
      (base >> 9) & 255,
      (base >> 1) & 255,
      ((base & 1) << 7) | 0x7e | (ext >> 8),
      ext & 255,
    ]);
    _bytes.add(packet);
    _lastClock = base;
  }

  // Rebase both decode and presentation timestamps along with the pack SCR.
  // Adjacent DVD cells can restart at identical presentation timestamps.
  void _stamp(Uint8List b, int at) {
    final pts =
        ((b[at] & 14) << 29) |
        (b[at + 1] << 22) |
        ((b[at + 2] & 254) << 14) |
        (b[at + 3] << 7) |
        (b[at + 4] >> 1);
    final value = (pts + clockOffset) & 0x1ffffffff;
    b[at] = (b[at] & 0xf1) | ((value >> 29) & 14);
    b[at + 1] = (value >> 22) & 255;
    b[at + 2] = ((value >> 14) & 254) | 1;
    b[at + 3] = (value >> 7) & 255;
    b[at + 4] = ((value << 1) & 254) | 1;
  }

  void _pes(int pid, Uint8List pes) {
    final flags = pes[7] >> 6;
    if (flags == 1 || flags >= 2 && pes[8] < (flags == 3 ? 10 : 5)) {
      invalidDisc();
    }
    if (flags >= 2) {
      pes = Uint8List.fromList(pes);
      _stamp(pes, 9);
    }
    if (flags == 3) _stamp(pes, 14);

    var cc = _cc[pid] ?? 0;
    for (var off = 0; off < pes.length;) {
      final reset = pid == _audio && off == 0 && !_cc.containsKey(pid);
      final n = (pes.length - off).clamp(0, reset ? 182 : 184);
      final packet = Uint8List(188);
      packet[0] = 0x47;
      packet[1] = (pid >> 8) | (off == 0 ? 0x40 : 0);
      packet[2] = pid & 255;
      packet[3] = (n == 184 ? 0x10 : 0x30) | cc;
      if (n < 184) {
        packet[4] = 183 - n;
        if (reset) packet[5] = 0x80;
        if (n < 182) packet.fillRange(6, 188 - n, 255);
      }
      packet.setRange(188 - n, 188, pes, off);
      _bytes.add(packet);
      cc = (cc + 1) & 15;
      off += n;
    }
    _cc[pid] = cc;
  }

  void addSectors(Uint8List b) {
    final data = ByteData.sublistView(b);
    if (b.length % 2048 != 0) invalidDisc();
    for (int i = 0; i < b.length; i += 2048) {
      final end = i + 2048;
      if (data.getUint32(i) != 0x1ba || (b[i + 4] & 0xc0) != 0x40) {
        invalidDisc();
      }
      _clock(b, i);
      var at = i + 14 + (b[i + 13] & 7);
      while (at + 6 <= end) {
        if (data.getUint16(at) != 0 || b[at + 2] != 1) invalidDisc();
        final id = b[at + 3], next = at + 6 + data.getUint16(at + 4);
        if (next > end) invalidDisc();
        if (id == 0xe0 ||
            (audio != null &&
                (audio!.ac3 ? id == 0xbd : id == audio!.stream))) {
          if (at + 9 > next || (b[at + 6] & 0xf0) != 0x80) invalidDisc();
          // Scrambled PES payloads cannot be remuxed as clear DVD video.
          final payload = at + 9 + b[at + 8];
          if (payload > next) invalidDisc();
          if (id == 0xe0) {
            _videoSeen = true;
            _pes(_video, Uint8List.sublistView(b, at, next));
          } else if (id != 0xbd) {
            _pes(_audio, Uint8List.sublistView(b, at, next));
          } else if (payload < next && b[payload] == audio!.stream) {
            if (payload + 4 > next) invalidDisc();
            final out = Uint8List(next - at - 4);
            out.setRange(0, payload - at, b, at);
            out.setRange(payload - at, out.length, b, payload + 4);
            ByteData.sublistView(out).setUint16(4, out.length - 6);
            _pes(_audio, out);
          }
        }
        at = next;
      }
    }
  }

  Uint8List finish() {
    if (!_videoSeen) invalidDisc();
    return _bytes.takeBytes();
  }
}
