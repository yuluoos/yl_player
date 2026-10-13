import 'dart:convert';

List<int> num(int n, [int size = 4]) => [
  for (var i = size - 1; i >= 0; i--) (n >> (8 * i)) & 255,
];
List<int> box(String type, List<int> data, {bool large = false}) => [
  ...num(large ? 1 : data.length + 8),
  ...ascii.encode(type),
  if (large) ...num(data.length + 16, 8),
  ...data,
];
List<int> full(String type, List<int> data, {int version = 0, int flags = 0}) =>
    box(type, [version, ...num(flags, 3), ...data]);
List<int> textSample(String text, {List<int> extra = const []}) {
  final b = utf8.encode(text);
  return [...num(b.length, 2), ...b, ...extra];
}

List<int> style({
  int start = 0,
  int end = 0,
  int face = 0,
  int color = 0xffffffff,
  int font = 1,
  int size = 18,
}) => [
  ...num(start, 2),
  ...num(end, 2),
  ...num(font, 2),
  face,
  size,
  ...num(color),
];
List<int> description({
  String codec = 'tx3g',
  int display = 0,
  int horizontal = 1,
  int vertical = 255,
  List<int>? defaults,
  List<int> extra = const [],
}) => box(codec, [
  ...List.filled(6, 0),
  ...num(1, 2),
  ...num(display),
  horizontal,
  vertical,
  ...List.filled(12, 0),
  ...(defaults ?? style()),
  ...box('ftab', [...num(1, 2), ...num(1, 2), 5, ...ascii.encode('Arial')]),
  ...extra,
]);

class Mp4Track {
  Mp4Track({
    this.id = 1,
    this.scale = 1000,
    this.language = 'eng',
    this.handler = 'sbtl',
    List<List<int>>? samples,
    List<int>? durations,
    this.entry,
    this.edits,
    this.ctts,
    this.co64 = false,
    this.compact = false,
    this.extra = const [],
    this.stblExtra = const [],
    this.mediaExtra = const [],
    this.enabled = true,
    this.chunkSizes,
    this.descriptionIndices,
    this.entries,
    this.sizeBits = 16,
    this.commonSize,
  }) : samples = samples ?? [textSample('hello')],
       durations = durations ?? [1000];
  final int id, scale;
  final String language, handler;
  final List<List<int>> samples;
  final List<int> durations;
  final List<int>? entry, edits, ctts;
  final bool co64, compact, enabled;
  final List<int>? chunkSizes, descriptionIndices;
  final List<List<int>>? entries;
  final int sizeBits;
  final int? commonSize;
  final List<int> extra, stblExtra, mediaExtra;
  List<int> build(int offset) {
    final lang = language.codeUnits.fold(0, (v, c) => (v << 5) | (c - 0x60));
    final chunks = chunkSizes ?? (samples.isEmpty ? <int>[] : [samples.length]);
    var sampleAt = 0, chunkOffset = offset;
    final offsets = [
      for (final c in chunks)
        (() {
          final start = chunkOffset;
          for (var i = 0; i < c; i++) {
            chunkOffset += samples[sampleAt++].length;
          }
          return start;
        })(),
    ];
    return box('trak', [
      ...full('tkhd', [
        ...num(0),
        ...num(0),
        ...num(id),
        ...num(0),
        ...num(10000),
        ...List.filled(60, 0),
      ], flags: enabled ? 3 : 2),
      if (edits != null) ...box('edts', edits!),
      ...box('mdia', [
        ...full('mdhd', [
          ...num(0),
          ...num(0),
          ...num(scale),
          ...num(durations.fold(0, (a, b) => a + b)),
          ...num(lang, 2),
          0,
          0,
        ]),
        ...mediaExtra,
        ...full('hdlr', [
          ...num(0),
          ...ascii.encode(handler),
          ...List.filled(12, 0),
          ...utf8.encode('Subtitle $id'),
          0,
        ]),
        ...box('minf', [
          ...box(
            'dinf',
            full('dref', [...num(1), ...full('url ', [], flags: 1)]),
          ),
          ...box('stbl', [
            ...full('stsd', [
              ...num(entries?.length ?? 1),
              if (entries != null)
                for (final e in entries!) ...e
              else
                ...(entry ?? description()),
            ]),
            ...full('stts', [
              ...num(durations.length),
              for (final d in durations) ...[...num(1), ...num(d)],
            ]),
            ...?ctts,
            ...full('stsc', [
              ...num(chunks.length),
              for (var i = 0; i < chunks.length; i++) ...[
                ...num(i + 1),
                ...num(chunks[i]),
                ...num(descriptionIndices?[i] ?? 1),
              ],
            ]),
            if (compact)
              ...full('stz2', [
                0,
                0,
                0,
                sizeBits,
                ...num(samples.length),
                if (sizeBits == 4)
                  for (var i = 0; i < samples.length; i += 2)
                    (samples[i].length << 4) |
                        (i + 1 < samples.length ? samples[i + 1].length : 0)
                else
                  for (final s in samples) ...num(s.length, sizeBits ~/ 8),
              ])
            else
              ...full('stsz', [
                ...num(commonSize ?? 0),
                ...num(samples.length),
                if (commonSize == null)
                  for (final s in samples) ...num(s.length),
              ]),
            ...full(co64 ? 'co64' : 'stco', [
              ...num(offsets.length),
              for (final start in offsets) ...num(start, co64 ? 8 : 4),
            ]),
            ...stblExtra,
          ]),
        ]),
      ]),
      ...extra,
    ]);
  }
}

List<int> mp4({
  List<Mp4Track>? tracks,
  bool fastStart = false,
  int padding = 0,
  List<int> extra = const [],
  List<int> moovExtra = const [],
}) {
  tracks ??= [Mp4Track()];
  final ftyp = box('ftyp', [
    ...ascii.encode('isom'),
    ...num(0),
    ...ascii.encode('isommp42'),
  ]);
  final free = box('free', List.filled(padding, 0));
  List<int> movie(int start) {
    var offset = start;
    return box('moov', [
      ...full('mvhd', [
        ...num(0),
        ...num(0),
        ...num(1000),
        ...num(10000),
        ...List.filled(80, 0),
      ]),
      for (final t in tracks!)
        ...(() {
          final b = t.build(offset);
          offset += t.samples.fold<int>(0, (a, s) => a + s.length);
          return b;
        })(),
      ...moovExtra,
    ]);
  }

  final m = movie(
    ftyp.length + free.length + 8 + (fastStart ? movie(0).length : 0),
  );
  final data = box('mdat', [
    for (final t in tracks)
      for (final s in t.samples) ...s,
  ]);
  return [
    ...ftyp,
    ...free,
    if (fastStart) ...m,
    ...data,
    if (!fastStart) ...m,
    ...extra,
  ];
}
