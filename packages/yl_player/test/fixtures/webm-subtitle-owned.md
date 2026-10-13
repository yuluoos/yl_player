# Owned WebM subtitle fixture

Host FFmpeg8.0.1 muxed owned black VP9 video and authored WebVTT into
`webm-subtitle-owned.webm`. One D_WEBVTT/SUBTITLES cue is encoded at
0.503–1.707s, bold text, ID owned-id, position25%,line-left align:start.
Input/command/probe/hashes are in the
[evidence directory](../../../../docs/superpowers/reports/evidence/2026-10-12-subtitle-webm/manifest.json).
No third-party media or runtime dependency; fixture tests subtitle extraction, not native decoding.
