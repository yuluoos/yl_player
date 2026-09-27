# Owned sidx fixtures

These two video-only files support P01 Task 1's pure index parser tests. They
do not establish SegmentBase network, audio, playback or seek support.

Run from the repository root:

```sh
python3 -B tool/dash_sidx/generate_fixture.py
python3 -B -m unittest discover -s tool/dash_sidx -p 'test_*.py'
shasum -a 256 -c tool/dash_sidx/SHA256SUMS
```

The input is the repository's [synthetic DASH fixture](../../packages/yl_player/example/assets/test_media/dash/README.md):
`period0/init-0.m4s` plus `chunk-0-00001.m4s` through `chunk-0-00004.m4s`.
Its original [hash ledger](../../packages/yl_player/example/assets/test_media/dash/SHA256SUMS)
pins the inputs. These contain FFmpeg-generated testsrc, no third-party media.
The new generator uses only Python's standard library. It inserts one global
flat sidx after initialization, without changing any original media bytes.
The fragments retain their local boxes; the global index references complete
fragments including those headers, using `reference_type=0`.

The 320×180, 24 fps AVC Constrained Baseline video has four one-second fragments.
The existing manifest declares SAP 1 and one-second boundaries; the global
index records startsWithSAP=true, SAP type=1, SAP delta=0. ffprobe inspection
on 2026-09-27 confirmed time_base=1/12288, duration=4.000000 and keyframe PTS/DTS
0, 12288, 24576, 36864. This metadata check is not a seek acceptance test.

`fixtures.json` records absolute byte offsets, exclusive index ends, unsigned
media ticks, SAP values and reference ID. Both versions use timescale=12288,
earliestPresentationTime=0 and firstOffset=0. The initialization is 826 bytes;
the index is 80 bytes in v0 or 88 in v1. SHA256SUMS pins the complete outputs.
Canonical resources live in `tool/consumer_fixtures/apple_flutter/Resources/`;
the iOS/macOS RunnerTests copies must remain byte-identical. The native test
inventory checks those copies and Xcode Sources/Resources membership.

The parser accepts exactly one explicit-size sidx box, at most 1 MiB. The caller
supplies its absolute exclusive end and a positive reference budget. Only flat
media references with positive size/duration are accepted. All cumulative byte
and time additions are checked. SAP bits remain raw metadata; a future loader
must validate its random-access subset, total session budgets, exact HTTP ranges,
and representable timeline conversion before authorizing playback.

The absolute offset rule and version widths were cross-checked with the
[AndroidX Media3 extractor's parseSidx implementation](https://github.com/androidx/media/blob/release/libraries/extractor/src/main/java/androidx/media3/extractor/mp4/FragmentedMp4Extractor.java).
No new runtime dependency or commercial SDK is introduced.
