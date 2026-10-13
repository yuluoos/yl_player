# Owned embedded PGS fixture

HostFFmpeg8.0.1 remuxed the existing authored pgsFixture SUP into MKV with
S_HDMV/PGS. Automatic frame merge produces three raw binary display-set packets,
encoded timestamps0/1/2s: white/red bitmap, palette recolor, clear. InputSUP is
1/2/3s; tests use actual container times. No third-party media/runtime dependency.
[Input/command/probe/hashes](../../../../docs/superpowers/reports/evidence/2026-10-12-subtitle-embedded-pgs/manifest.json).
