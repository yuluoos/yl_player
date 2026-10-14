# DASH timeline feasibility fixtures

These tools own the media in
`packages/yl_player/example/assets/test_media/dash_timeline`. No third-party
streams, credentials, DRM or SDK are involved. Generation uses FFmpeg 8.0.1
(libx264 AVC Baseline, AAC, 320×180 / 24 fps / 48 kHz). The two original four-second
Periods carry one solid color and one tone per second; `reference.vtt` labels the
expected program time. It is a reference, not evidence of rendered subtitles.

From the repository root:

```sh
python3 tool/dash_timeline/generate_fixture.py
python3 -B -m unittest discover -s tool/dash_timeline -p 'test_*.py'
python3 tool/dash_timeline/verify_markers.py
```

Generation rewrites owned files and their SHA256SUMS. Regenerating with another
encoder version may change the hashes; inspect the reference results before
updating the committed files. `verify_markers.py` independently concatenates init
and media bytes into temporary files (no remux), decodes center RGB and counts
positive audio zero crossings over each middle half-second. The ffprobe output
retains AAC priming: first packet PTS is -1024 at 48 kHz; this is not hidden by
claiming all packets start at zero. Encoded audio extends to 4 seconds.

`manifest.mpd` and `large-exact.mpd` address identical original bytes. The latter
scales MPD ticks and timescales by 10^9 without changing their rational values.
`matrix.json` preserves the seven dimensions rejected by the original HLS-only path and their exact expected clocks. Its `productionAcceptance` values are historical; the new native programme route has separate evidence in the P01 completion reports.
Fractional media has eight frames / 12288 timescale / 4096 total ticks. Independent
PTO uses **offline test copies** with video tfdt/sidx shifted 10 seconds and audio
20 seconds; init and encoded payload bytes are identical. Tests verify both
shifts and payload identity. This is fixture construction, never a production
rewrite or evidence that the playback path supports those PTOs.

A separate macOS experiment measures AVPlayer duration and decoded image PTS:

```sh
swiftc -parse-as-library tool/dash_timeline/probe.swift -o /tmp/yl-timeline-probe
python3 -m http.server 18769 --bind 127.0.0.1 --directory packages/yl_player/example/assets/test_media/dash_timeline
# In another terminal:
/tmp/yl-timeline-probe http://127.0.0.1:18769/baseline.m3u8
/tmp/yl-timeline-probe http://127.0.0.1:18769/independent.m3u8
/tmp/yl-timeline-probe http://127.0.0.1:18769/clip.m3u8
```

The probe is muted and has no audio tap. Missing RGB means no buffer observed in
its bounded sampling window, not proof that decoding is impossible on every OS.
It uses the pre-macOS-27 pixel-buffer API so the source also compiles with older
SDKs; macOS 27 emits deprecation warnings.

`clip.m3u8` deliberately changes EXTINF to 3.5 seconds while retaining four seconds
of media. It tests whether this shortcut clips samples; it is **not a valid
production clipping technique**. Baseline / independent playlists are also
experiment inputs, not compiler output. Only `player.load` integration tests
exercise the actual production DASH path. See the P01 execution report for
measured outcomes and remaining architecture work.

## Programme reconfiguration and Range regression media

`generate_period_fixture.py` adds three-second AVC→HEVC and AVC→AVC 320→640
programmes plus audio catalog addition/removal. Both new encoders use closed GOPs
with three B frames; each fragment has 24 packets and the four fragments have 96
unique PTS values. This is checked with ffprobe independently of playback. An
initial open-GOP HEVC draft produced duplicate muxed PTS and was replaced before
commit; its failed native runs remain in the evidence.

`generate_range_fixture.py` preserves original AVC sample payloads, adds absolute
`tfhd.base_data_offset` addresses, and places a 4096-byte free box between the
global index and media. SegmentBase and SegmentList reference identical bytes.
Native tests play both through actual managed Range requests, seek, and test an
8 GiB virtual offset with less than 1 MiB of assigned decoder workspace. No
8 GiB file or allocation is created. Separate provenance files pin these additions
without regenerating earlier media. `package_native_fixture.py` packages exact
media bytes into the canonical and iOS/macOS test resources.

## Real composition captures

`dash_subtitle_composition_test.dart` measures the rendered video marker and cue
pixels at paused programme positions. Android reads the actual Flutter external
texture composition. Apple uses native hybrid views; a RepaintBoundary snapshot
excludes their video layer and must not be treated as black-output evidence.
Start the loopback-only helper for the example window or the named simulator:

```sh
swiftc tool/dash_timeline/capture_window.swift -o /tmp/p01-capture-window
python3 tool/dash_timeline/capture_composition.py --platform macos --window-helper /tmp/p01-capture-window --output /tmp/p01-macos-captures
# Alternatively: --platform ios --simulator <UDID> --output /tmp/p01-ios-captures
# From packages/yl_player/example, use the token URL printed by that process:
flutter test integration_test/dash_subtitle_composition_test.dart -d macos --dart-define=P01_CAPTURE_URL=<printed-loopback-URL> --timeout 2m
```

The macOS helper requires existing screen-capture permission. It selects only the
unique largest window belonging to `dev.ylplayer.ylPlayerExample`; it does not
capture the whole desktop or another application. Captures are bounded and saved
as numbered PNG files. Stop the helper after the measurement. Frame capture cost
is reported separately and is not a seek latency measurement. The AVC fixtures
lack CICP metadata, so the assertion classifies nonoverlapping solid color
markers and retains raw RGB; this is timing/content identity evidence, not an
exact color reproduction test. The iOS screenshots use the explicitly named
simulator; simulator results do not stand in for physical display measurements.

## Short native AV observations

`joint_protocol.json` freezes three fresh player/resource scopes per owned
fixture, playback rate 1, loopback transport, and uncontrolled OS caches. The
native Apple `testProgramNativeJointBaseline` and Android
`YlDashJointInstrumentedTest` emit raw observations. This is an instrumented
short-run baseline; the new independent-PTO/cropping/reconfiguration path had no
playable old-path equivalent, and no speedup over an invented baseline is claimed.

Apple pairs actual published CVPixelBuffer RGB with the native audio node's
rendered clock at the observation host time. Android reads actual decoded YUV
from ImageReader, matches the image timestamp to Media3's frame metadata, and
records AudioTrack consumption. ImageReader can deliver before the requested
release instant; both raw consumption delta and the rate-1 projection to that
instant remain in the record. These are native output measurements, not physical
screen/speaker measurements. Separate Flutter/OS composition tests check visible
video and cue glyphs. The PCM tests verify decoded tone windows and exact sample
counts before AudioTrack, with actual end-of-stream drain observed separately.

```sh
python3 -B tool/dash_timeline/joint_observations.py captured-native.log --output summary.json
python3 -B -m unittest discover -s tool/dash_timeline -p test_joint_observations.py
```

The summarizer retains missing pairs as counts and absent metrics as null,
rejects duplicate runs and non-finite numbers, and never assigns test outcomes.
Keep the full source logs and XCTest/instrumentation result alongside it. The
first macOS baseline probe mislabeled the existing Period observer's milliseconds
as `waitUs`; use `--legacy-apple-wait-ms` only for that archived run. Later probes
emit `waitMs`. This explicit correction never rewrites the original evidence.
