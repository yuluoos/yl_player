import 'dart:convert';

List<int> be(int value, [int? width]) {
  width ??= (value.bitLength + 7) ~/ 8;
  if (width == 0) width = 1;
  return [for (var i = width - 1; i >= 0; i--) (value >> (i * 8)) & 255];
}

List<int> vint(int value) {
  var width = 1;
  while (value >= (1 << (7 * width)) - 1) {
    width++;
  }
  final bytes = be(value, width);
  bytes[0] |= 1 << (8 - width);
  return bytes;
}

List<int> element(int id, List<int> body) => [
  ...be(id),
  ...vint(body.length),
  ...body,
];
List<int> uint(int id, int value) => element(id, be(value));
List<int> str(int id, String value) => element(id, utf8.encode(value));
List<int> track({
  int number = 1,
  int uid = 101,
  String codec = 'S_TEXT/UTF8',
  String? private,
  String language = 'eng',
  String? ietf,
  bool forced = false,
  List<int> extra = const [],
}) => element(0xae, [
  ...uint(0xd7, number),
  ...uint(0x73c5, uid),
  ...uint(0x83, 17),
  ...str(0x86, codec),
  ...str(0x22b59c, language),
  if (ietf != null) ...str(0x22b59d, ietf),
  ...str(0x536e, 'Subtitle $uid'),
  ...uint(0x55aa, forced ? 1 : 0),
  if (private != null) ...str(0x63a2, private),
  ...extra,
]);
List<int> block({
  int number = 1,
  int time = 0,
  String text = 'hello',
  int? duration = 1000,
  bool simple = false,
  int flags = 0,
  List<int> extra = const [],
}) {
  final b = [
    ...vint(number),
    ...be(time & 0xffff, 2),
    flags,
    ...utf8.encode(text),
  ];
  return simple
      ? element(0xa3, b)
      : element(0xa0, [
          ...element(0xa1, b),
          if (duration != null) ...uint(0x9b, duration),
          ...extra,
        ]);
}

List<int> cluster(List<int> blocks, {int time = 1000}) =>
    element(0x1f43b675, [...uint(0xe7, time), ...blocks]);
List<int> mkv({
  List<int>? tracks,
  List<int>? clusters,
  int scale = 1000000,
  bool unknownSegment = false,
  String docType = 'matroska',
  List<int> extra = const [],
}) {
  final body = [
    ...element(0x1549a966, uint(0x2ad7b1, scale)),
    ...element(0x1654ae6b, tracks ?? track()),
    ...extra,
    ...(clusters ?? cluster(block())),
  ];
  return [
    ...element(0x1a45dfa3, [...str(0x4282, docType), ...uint(0x4285, 4)]),
    ...be(0x18538067),
    if (unknownSegment) 255 else ...vint(body.length),
    ...body,
  ];
}
