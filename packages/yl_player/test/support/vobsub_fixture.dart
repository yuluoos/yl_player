import 'dart:convert';
import 'pgs_fixture.dart' show be16;

// Original DVD SPU and MPEG-2 PS samples; no borrowed subtitle assets.
List<int> vobRect(int x, int y, int w, int h) => [
  x >> 4,
  ((x & 15) << 4) | ((x + w - 1) >> 8),
  (x + w - 1) & 255,
  y >> 4,
  ((y & 15) << 4) | ((y + h - 1) >> 8),
  (y + h - 1) & 255,
];
List<int> vobSpu({
  int x = 20,
  int y = 30,
  int w = 4,
  int h = 3,
  List<int> top = const [0x9a, 0, 3],
  List<int> bottom = const [0x11],
  int alpha = 0xf8f0,
  bool forced = false,
  bool stop = true,
  int startTicks = 0,
  int stopTicks = 90,
  List<int>? extra,
}) {
  final control = 4 + top.length + bottom.length;
  final commands = [
    3,
    0x32,
    0x10,
    4,
    ...be16(alpha),
    5,
    ...vobRect(x, y, w, h),
    6,
    ...be16(4),
    ...be16(4 + top.length),
    forced ? 0 : 1,
    ...?extra,
    0xff,
  ];
  final next = control + 4 + commands.length;
  return [
    ...be16(next + (stop ? 6 : 0)),
    ...be16(control),
    ...top,
    ...bottom,
    ...be16(startTicks),
    ...be16(stop ? next : control),
    ...commands,
    if (stop) ...[...be16(stopTicks), ...be16(next), 2, 0xff],
  ];
}

List<int> vobPes(List<int> payload, {int stream = 0, bool pts = true}) {
  final body = [
    0x80,
    pts ? 0x80 : 0,
    pts ? 5 : 0,
    if (pts) ...[0x21, 0, 1, 0, 1],
    0x20 + stream,
    ...payload,
  ];
  return [0, 0, 1, 0xbd, ...be16(body.length), ...body];
}

const vobPack = [0, 0, 1, 0xba, 0x44, 0, 4, 0, 4, 1, 0, 0, 3, 0xf8];
List<int> vobSub({List<int>? spu, int stream = 0, int? split}) {
  final unit = spu ?? vobSpu();
  return [
    ...vobPack,
    ...vobPes(split == null ? unit : unit.sublist(0, split), stream: stream),
    if (split != null) ...[
      ...vobPack,
      ...vobPes(unit.sublist(split), stream: stream, pts: false),
    ],
  ];
}

String vobIdxText({
  String time = '00:00:01:000',
  int pos = 0,
  int width = 100,
  int height = 100,
  int stream = 0,
  String language = 'en',
  String settings = '',
  String tail = '',
}) =>
    '''# VobSub index file, v7 (owned fixture)
size: ${width}x$height
palette: 000000, ffffff, ff0000, 00ff00, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000
$settings
id: $language, index: $stream
timestamp: $time, filepos: ${pos.toRadixString(16).padLeft(9, '0')}
$tail
''';
List<int> vobIdx() => utf8.encode(vobIdxText());

List<int> vobAnimated({List<int>? initial}) {
  final first = initial ?? vobSpu(stop: false),
      control = (first[2] << 8) | first[3];
  final second = first.length, last = second + 8;
  first[control + 2] = second >> 8;
  first[control + 3] = second & 255;
  final all = [
    ...first,
    ...be16(45),
    ...be16(last),
    4,
    0xf0,
    0xf0,
    0xff,
    ...be16(90),
    ...be16(last),
    2,
    0xff,
  ];
  all[0] = all.length >> 8;
  all[1] = all.length & 255;
  return all;
}

List<int> vobExtendedPes(
  List<int> spu, {
  List<int> extension = const [0x1e, 0x60, 0x3a],
}) {
  final body = [
    0x81,
    0x81,
    5 + extension.length,
    0x21,
    0,
    1,
    0,
    1,
    ...extension,
    0x20,
    ...spu,
  ];
  return [0, 0, 1, 0xbd, ...be16(body.length), ...body];
}

List<int> vobPad(List<int> spu, List<int> padding) {
  final b = [...spu, ...padding];
  b[0] = b.length >> 8;
  b[1] = b.length & 255;
  return b;
}
