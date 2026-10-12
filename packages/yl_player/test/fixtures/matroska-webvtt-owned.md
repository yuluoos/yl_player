# Owned Matroska WebVTT fixture

`matroska-webvtt-owned.mkv` is a subtitle-only MKV muxed by host FFmpeg 8.0.1
from authored WebVTT. No third-party media. The D_WEBVTT/SUBTITLES stream contains
one bold cue with ID `owned-id`, `position:25%,line-left align:start`, encoded
time0.503–1.707s. Input, command, ffprobe and hashes are in
[the evidence directory](../../../../docs/superpowers/reports/evidence/2026-10-12-subtitle-matroska-webvtt/manifest.json).
This fixture verifies the independent muxer mapping, not native video playback.
