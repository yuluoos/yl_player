# Synthetic DASH fixture

This directory contains an eight-second static MPEG-DASH fixture generated
locally from FFmpeg `testsrc` video and `sine` audio. It contains two
four-second Periods. Both use 320x180, 24 fps H.264 Constrained Baseline video
and 48 kHz mono AAC audio; only the sine frequency changes (440 Hz then 660 Hz).
No third-party media is included.

Regenerate from the repository root:

```sh
tool/generate_dash_fixture.sh
```

Generation used FFmpeg 8.0.1. The script records every generated file hash in
`SHA256SUMS`. The fixture is intentionally bounded: four one-second video
segments and five finite audio segments per Period, with no dynamic MPD or DRM.
