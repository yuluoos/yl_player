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
`matrix.json` records seven still-rejected dimensions and exact expected clocks.
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
