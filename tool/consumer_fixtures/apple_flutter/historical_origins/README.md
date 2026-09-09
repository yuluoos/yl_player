# Historical Apple source-copy and declaration proof — R16

This independent fixture preserves the source-copy/declaration proof at `81d261c445f70df09f18458707ba1e8eb1e2d71f`, when all recorded source, replacement and declaration hashes match. It must not be described as a current playback gate or a passing copy-origin gate at `65cdfd5` (which already contains a later HLS credential-context change).

The archive contains 86 exact Git source blobs / 752,725 source bytes and two unchanged metadata blobs, totaling 88 entries. Original source-parity SHA-256 is `da1a9778589c572895110e0c00203fc68cf3ac000b55a0a1eb78d136e4973df0`; source-declarations SHA-256 is `276554c0775260fc0da04a884251011a436f594654f05ca91a4df2544a04a526`.

Archive SHA-256: `86dd8fc749df40893cf8573b1ae99107375f1de724737a9afe89fafbe07de803`; compressed size: 161,198 bytes. Generation used sorted USTAR entries, zero timestamps/owners, mode 0644 and gzip mtime 0. The pinned manifest, complete archive, exact entry inventory, regular paths and per-entry sizes/digests are validated using the R14 mechanism. Verification uses no Git, network or current Apple sources.

Run `python3 -B tool/consumer_fixtures/apple_flutter/source_parity.py --verify-identical`. Explicit `--capture-live` and `--verify-live` modes retain the comparison utility for future extraction work; they are not the default historical gate. Current behavior is covered by task contract tests and consolidated final acceptance.
