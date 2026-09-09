# Historical Apple behavioral migration proof — R14

This fixture verifies only accepted Task 1 (`65cdfd5e4a7b22812a66582c16988fb07be59876`). It does not compare current playback semantics with legacy behavior.

The deterministic archive contains exact Git blobs: 98 source files / 1,006,867 source bytes, the unchanged 57-row behavioral allowlist, three finite fold records, and the original R13 compressed before-source blob. All 101 entries are individually hashed in `manifest.json`; the verifier pins that manifest and validates the entire content-addressed archive before checking safe regular-file entries.

Archive SHA-256: `9460ebb0d6215be2a8908180029f85ba62442bb055ccb86cb393d16d0b40c44d`; compressed size: 224,982 bytes. Generation used sorted USTAR entries, zero timestamps/owners, mode 0644, gzip mtime 0, and only exact accepted revision blobs. No working-tree source or build product was captured.

Run `python3 -B tool/consumer_fixtures/apple_flutter/behavioral_constants.py` from the repository root. Verification requires no Git history, network, or live Apple package source. The live comparison/normalization functions remain available to focused extraction tests. Source-copy/declaration origin proof has a different verified boundary; see the adjacent `historical_origins` fixture.
