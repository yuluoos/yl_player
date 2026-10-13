# Owned Matroska compression-chain golden

`subtitle-chain-owned.json` was generated with Python stdlib `zlib.compress`,
applied twice independently to `WEBVTT` and `<b>hello</b>`. Base64 stores exact
compressed bytes, with one-layer byte lengths supplied for inspection. Input
text is original to this repository. The actual-file test builds an owned EBML
container and uses these precomputed bytes, bypassing the Dart fixture encoder.
This is an independent compression check, not independent Matroska muxer or
physical-device evidence. No runtime dependency or external media is added.
