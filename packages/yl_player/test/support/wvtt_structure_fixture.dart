import 'fmp4_fixture.dart';
export 'fmp4_fixture.dart';

/// Empty payloads exercise structural work without exhausting the cue budget.
/// Each vttc/payl pair costs two boxes; a standalone vtte costs one.
List<List<int>> structureSamples(int boxes) {
  final pair = vttCue('');
  final full = [for (var i = 0; i < 64; i++) ...pair];
  return [
    for (var i = 0; i < boxes ~/ 128; i++) full,
    if (boxes % 128 ~/ 2 > 0)
      [for (var i = 0; i < boxes % 128 ~/ 2; i++) ...pair],
    if (boxes.isOdd) box('vtte', []),
  ];
}

/// Hand-counted container overhead: 22 boxes for a single ordinary track,
/// including vttC; mvex/trex/free and one fragment add 11 more.
List<int> structureFile(String layout, int sampleBoxes, {List<int>? entry}) {
  final samples = structureSamples(sampleBoxes);
  final split = layout == 'hybrid' ? samples.length ~/ 2 : 0;
  final initial = layout == 'ordinary' ? samples : samples.take(split).toList();
  final track = Mp4Track(
    entry: entry ?? wvttEntry(),
    samples: initial,
    durations: List.filled(initial.length, 1),
  );
  if (layout == 'ordinary') return mp4(tracks: [track]);
  final later = samples.skip(split).toList();
  return fragmented(
    tracks: [track],
    fragments: [
      Fragment(
        tracks: [
          FragmentTrack(
            time: initial.length,
            samples: later,
            durations: List.filled(later.length, 1),
          ),
        ],
      ),
    ],
  );
}
