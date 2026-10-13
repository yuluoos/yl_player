import 'matroska_fixture.dart';
import 'pgs_fixture.dart';

// Convert owned SUP framing into Matroska raw PGS segments, never UTF8.
List<({int time, List<int> bytes})> pgsPackets(List<int> sup) {
  final packets = <({int time, List<int> bytes})>[];
  for (var p = 0; p < sup.length;) {
    var pts = 0;
    for (var i = 2; i < 6; i++) {
      pts = pts * 256 + sup[p + i];
    }
    final length = sup[p + 11] * 256 + sup[p + 12];
    packets.add((
      time: pts * 1000 ~/ 90000,
      bytes: sup.sublist(p + 10, p + 13 + length),
    ));
    p += 13 + length;
  }
  return packets;
}

List<int> pgsBlock(
  List<int> bytes, {
  int number = 1,
  int time = 1000,
  int? duration,
  bool simple = false,
  List<int> extra = const [],
}) {
  final body = [...vint(number), ...be(time & 65535, 2), 0, ...bytes];
  return simple
      ? element(0xa3, body)
      : element(0xa0, [
          ...element(0xa1, body),
          if (duration != null) ...uint(0x9b, duration),
          ...extra,
        ]);
}

List<int> embeddedPgs({
  List<int>? sup,
  bool merged = false,
  int number = 1,
  int uid = 101,
  int? duration,
  int padding = 0,
}) {
  final packets = pgsPackets(sup ?? pgsFixture());
  final groups = <int, List<int>>{};
  for (final p in packets) {
    groups.putIfAbsent(p.time, () => []).addAll(p.bytes);
  }
  return mkv(
    tracks: track(number: number, uid: uid, codec: 'S_HDMV/PGS'),
    extra: element(0xec, List.filled(padding, 0)),
    clusters: cluster([
      if (merged)
        for (final e in groups.entries)
          ...pgsBlock(e.value, number: number, time: e.key, duration: duration)
      else
        for (final p in packets)
          ...pgsBlock(
            p.bytes,
            number: number,
            time: p.time,
            duration: duration,
            simple: duration == null,
          ),
    ], time: 0),
  );
}
