import 'mp4_fixture.dart';
import 'wvtt_fixture.dart' show wvttEntry, vttCue;
export 'mp4_fixture.dart';
export 'wvtt_fixture.dart' show wvttEntry, vttCue;
export 'stpp_fixture.dart' show stppEntry, stppSample, ttmlDocument;

class FragmentTrack {
  FragmentTrack({
    this.id = 1,
    this.time = 0,
    List<List<int>>? samples,
    List<int>? durations,
    this.cts,
    this.defaultDuration,
    this.defaultSize,
    this.defaultFlags,
    this.description,
    this.base = 'moof',
    this.baseValue,
    this.timeVersion = 1,
    this.runVersion = 1,
    this.omitTime = false,
    this.durationEmpty = false,
    this.writeDurations = true,
    this.writeSizes = true,
    this.runCounts,
    this.firstFlags,
    this.sampleFlags,
    this.omitFirstOffset = false,
    this.extra = const [],
    this.tfhdExtraFlags = 0,
    this.trunExtraFlags = 0,
  }) : samples = samples ?? [vttCue('hello')],
       durations = durations ?? [1000];
  final int id, time, timeVersion, runVersion, tfhdExtraFlags, trunExtraFlags;
  final List<List<int>> samples;
  final List<int> durations;
  final List<int>? cts, runCounts, sampleFlags;
  final int? defaultDuration,
      defaultSize,
      defaultFlags,
      description,
      baseValue,
      firstFlags;
  final String base;
  final bool omitTime,
      durationEmpty,
      writeDurations,
      writeSizes,
      omitFirstOffset;
  final List<int> extra;
  List<int> build(int moofOffset, int payloadOffset) {
    final baseOffset = baseValue ?? moofOffset;
    final flags =
        tfhdExtraFlags |
        (base == 'moof'
            ? 0x020000
            : base == 'explicit'
            ? 1
            : 0) |
        (description != null ? 2 : 0) |
        (defaultDuration != null ? 8 : 0) |
        (defaultSize != null ? 16 : 0) |
        (defaultFlags != null ? 32 : 0) |
        (durationEmpty ? 0x010000 : 0);
    var at = 0, pos = payloadOffset;
    final runs = <int>[];
    for (final count in runCounts ?? [samples.length]) {
      final first = at == 0;
      final withOffset = first && !omitFirstOffset;
      final runFlags =
          trunExtraFlags |
          (withOffset ? 1 : 0) |
          (firstFlags != null ? 4 : 0) |
          (writeDurations ? 0x100 : 0) |
          (writeSizes ? 0x200 : 0) |
          (sampleFlags != null ? 0x400 : 0) |
          (cts != null ? 0x800 : 0);
      runs.addAll(
        full(
          'trun',
          [
            ...num(count),
            if (withOffset)
              ...num(pos - (base == 'explicit' ? baseOffset : moofOffset)),
            if (firstFlags != null) ...num(firstFlags!),
            for (var k = 0; k < count; k++) ...[
              if (writeDurations) ...num(durations[at + k]),
              if (writeSizes) ...num(samples[at + k].length),
              if (sampleFlags != null) ...num(sampleFlags![at + k]),
              if (cts != null) ...num(cts![at + k]),
            ],
          ],
          version: runVersion,
          flags: runFlags,
        ),
      );
      for (var k = 0; k < count; k++) {
        pos += samples[at + k].length;
      }
      at += count;
    }
    return box('traf', [
      ...full('tfhd', [
        ...num(id),
        if (base == 'explicit') ...num(baseOffset, 8),
        if (description != null) ...num(description!),
        if (defaultDuration != null) ...num(defaultDuration!),
        if (defaultSize != null) ...num(defaultSize!),
        if (defaultFlags != null) ...num(defaultFlags!),
      ], flags: flags),
      if (!omitTime)
        ...full(
          'tfdt',
          num(time, timeVersion == 1 ? 8 : 4),
          version: timeVersion,
        ),
      ...runs,
      ...extra,
    ]);
  }
}

class Fragment {
  Fragment({
    this.sequence = 1,
    List<FragmentTrack>? tracks,
    this.large = false,
    this.dataFirst = false,
    this.extra = const [],
    this.padding = 0,
  }) : tracks = tracks ?? [FragmentTrack()];
  final int sequence, padding;
  final List<FragmentTrack> tracks;
  final bool large, dataFirst;
  final List<int> extra;
  List<int> build(int start) {
    final payload = [
      for (final t in tracks)
        for (final s in t.samples) ...s,
    ];
    final mdat = box('mdat', payload, large: large);
    final moofOffset = start + (dataFirst ? mdat.length : 0);
    List<int> moof(int dataOffset) {
      var offset = dataOffset;
      return box('moof', [
        ...full('mfhd', num(sequence)),
        for (final t in tracks)
          ...(() {
            final b = t.build(moofOffset, offset);
            offset += t.samples.fold<int>(0, (n, s) => n + s.length);
            return b;
          })(),
        ...extra,
      ], large: large);
    }

    final preliminary = moof(0);
    final finalMoof = moof(
      dataFirst
          ? start + (large ? 16 : 8)
          : start + preliminary.length + padding + 8 + (large ? 16 : 8),
    );
    return dataFirst
        ? [...mdat, ...finalMoof]
        : [...finalMoof, ...box('free', List.filled(padding, 0)), ...mdat];
  }
}

List<int> fragmented({
  List<Mp4Track>? tracks,
  List<Fragment>? fragments,
  List<int>? trex,
  int padding = 0,
  List<int> mvexExtra = const [],
}) {
  tracks ??= [Mp4Track(entry: wvttEntry(), samples: [], durations: [])];
  final init = mp4(
    tracks: tracks,
    moovExtra: box('mvex', [
      if (trex != null)
        ...trex
      else
        for (final t in tracks)
          ...full('trex', [
            ...num(t.id),
            ...num(1),
            ...num(0),
            ...num(0),
            ...num(0),
          ]),
      ...mvexExtra,
    ]),
  );
  final out = [...init, ...box('free', List.filled(padding, 0))];
  for (final fragment in fragments ?? [Fragment()]) {
    out.addAll(fragment.build(out.length));
  }
  return out;
}
