// Owned synthetic SUP streams. No borrowed subtitle/font/image assets.
List<int> be16(int n) => [(n >> 8) & 255, n & 255];
List<int> be24(int n) => [(n >> 16) & 255, ...be16(n)];
List<int> be32(int n) => [(n >> 24) & 255, ...be24(n)];
List<int> pgsSegment(
  int type,
  List<int> body, {
  int pts = 90000,
  int dts = 0,
}) => [
  0x50,
  0x47,
  ...be32(pts),
  ...be32(dts),
  type,
  ...be16(body.length),
  ...body,
];
List<int> pgsRef({
  int id = 1,
  int window = 0,
  int x = 20,
  int y = 30,
  bool forced = false,
  List<int>? crop,
}) => [
  ...be16(id),
  window,
  (forced ? 0x40 : 0) | (crop == null ? 0 : 0x80),
  ...be16(x),
  ...be16(y),
  if (crop != null) ...crop.expand(be16),
];
List<int> pgsPcs({
  int pts = 90000,
  int state = 0x80,
  int number = 0,
  int palette = 0,
  bool update = false,
  int width = 100,
  int height = 100,
  List<List<int>>? objects,
}) => pgsSegment(0x16, [
  ...be16(width),
  ...be16(height),
  0x10,
  ...be16(number),
  state,
  update ? 0x80 : 0,
  palette,
  (objects ?? [pgsRef()]).length,
  ...(objects ?? [pgsRef()]).expand((o) => o),
], pts: pts);
List<int> pgsWindow({
  int x = 0,
  int y = 0,
  int w = 100,
  int h = 100,
  int pts = 90000,
}) => pgsSegment(0x17, [
  1,
  0,
  ...be16(x),
  ...be16(y),
  ...be16(w),
  ...be16(h),
], pts: pts);
List<int> pgsPalette({
  int id = 0,
  int version = 0,
  int pts = 90000,
  List<List<int>>? entries,
}) => pgsSegment(0x14, [
  id,
  version,
  ...(entries ??
          [
            [0, 16, 128, 128, 0],
            [1, 235, 128, 128, 255],
            [2, 81, 240, 90, 128],
          ])
      .expand((v) => v),
], pts: pts);
List<int> pgsObject({
  int id = 1,
  int version = 0,
  int flags = 0xc0,
  int w = 4,
  int h = 2,
  int? length,
  List<int>? data,
  int pts = 90000,
}) {
  final bytes = data ?? [1, 1, 2, 2, 0, 0, 0, 0x84, 1, 0, 0];
  return pgsSegment(0x15, [
    ...be16(id),
    version,
    flags,
    if (flags & 0x80 != 0) ...[
      ...be24(length ?? bytes.length + 4),
      ...be16(w),
      ...be16(h),
    ],
    ...bytes,
  ], pts: pts);
}

List<int> pgsEnd([int pts = 90000]) => pgsSegment(0x80, [], pts: pts);
List<int> pgsFixture({bool paletteUpdate = true, bool clear = true}) => [
  ...pgsPcs(),
  ...pgsWindow(),
  ...pgsPalette(),
  ...pgsObject(),
  ...pgsEnd(),
  if (paletteUpdate) ...[
    ...pgsPcs(pts: 180000, state: 0, number: 1, update: true),
    ...pgsPalette(
      pts: 180000,
      version: 1,
      entries: [
        [1, 16, 128, 128, 255],
      ],
    ),
    ...pgsEnd(180000),
  ],
  if (clear) ...[
    ...pgsPcs(pts: 270000, state: 0, number: 2, objects: []),
    ...pgsEnd(270000),
  ],
];
