import 'wvtt_structure_fixture.dart';
export 'wvtt_structure_fixture.dart';

/// Seventeen descriptions keep each stsd below the existing 256 KiB read cap.
/// Container overhead is 5 common + 17 * 17 track/ftab boxes = 294.
List<int> configurationFile(int extraBoxes) {
  final bitrate = box('btrt', List.filled(12, 0));
  return mp4(
    tracks: [
      for (var i = 0; i < 17; i++)
        Mp4Track(
          id: i + 1,
          samples: [],
          durations: [],
          entry: description(
            extra: [
              for (
                var k = 0;
                k < extraBoxes ~/ 17 + (i < extraBoxes % 17 ? 1 : 0);
                k++
              )
                ...bitrate,
            ],
          ),
        ),
    ],
  );
}

List<int> styledEmpty() => textSample('', extra: box('styl', num(0, 2)));

/// WVTT provides empty structural work; tx3g contributes font/modifier boxes.
/// Base overhead: 39 ordinary; 51 with mvex/two trex/free and one fragment.
List<int> modifierFile(String layout, int vttBoxes, {bool styled = true}) {
  final samples = structureSamples(vttBoxes);
  final filler = Mp4Track(
    entry: wvttEntry(),
    samples: samples,
    durations: List.filled(samples.length, 1),
  );
  final txSample = styled ? styledEmpty() : textSample('');
  final tx = Mp4Track(
    id: 2,
    samples: layout == 'fragmented' ? [] : [txSample],
    durations: layout == 'fragmented' ? [] : [1],
  );
  if (layout == 'ordinary') return mp4(tracks: [filler, tx]);
  return fragmented(
    tracks: [filler, tx],
    fragments: [
      Fragment(
        tracks: [
          FragmentTrack(
            id: 2,
            time: layout == 'hybrid' ? 1 : 0,
            samples: [txSample],
            durations: [1],
          ),
        ],
      ),
    ],
  );
}
