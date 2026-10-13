# Owned zlib golden streams

Generated independently with Python stdlib `zlib`, version recorded in the JSON.
Original bytes: `bytes((i*i + 11*i) % 251 for i in range(7000))`. Compress with
`compressobj(level, DEFLATED, 15, 8, strategy)` and finish with `flush()`:

- stored: level 0, Z_DEFAULT_STRATEGY
- fixed: level 6, Z_FIXED
- dynamic: level 6, Z_DEFAULT_STRATEGY

The fixture includes exact base64 inputs/outputs and decoded SHA256. No borrowed
media or runtime dependency. Tests additionally use the Dart SDK encoder with
multiple levels/strategies, malformed manual bitstreams and native-codec-neutral
owned Matroska wrappers. This is independent zlib evidence, not independent
Matroska muxer or physical-device certification.
