# Compressed CM4 transport: optional research overlay

The upstream archive remains pinned to dovi_tool commit
`614c816b6446dcd1dbaf433403d499a6026fbb5a`, archive SHA-256
`23e6e0b8262f03ed999d0170a304eac5ba544ea5a5497adf2db7b33026d957c1`.
Default builds remain unmodified. This is a local research compatibility change,
not an upstream fix, licensed conformance result or new player capability.

## Context and scope

FFmpeg n8.0.1 `dovi_rpudec.c` clears dynamic extension blocks on each record,
retains static blocks on compression and rejects signalled static blocks in its
strict mode. `dovi_rpu.h` classifies L10/L254 as static. Sources:
https://github.com/FFmpeg/FFmpeg/blob/n8.0.1/libavcodec/dovi_rpudec.c
https://github.com/FFmpeg/FFmpeg/blob/n8.0.1/libavcodec/dovi_rpu.h

The pinned libdovi instead requires L254 in every CM4 container. The explicit
`compressed_cm4_overlay.json` changes only two extracted research source files:
full-record validation remains unchanged; compressed CM4 validates allowed
L3/L8/L9/L11 and original block counts, while forbidding static L10/L254 and
other unsupported levels. No bytes are rewritten before parsing and no L254 is
fabricated. Original bit-length, field validation and CRC checks still run.
Python then enforces same ID/configuration, valid color history, unique targets,
known fields/counts/lengths and a retained L254 from a complete CM4 record.
A complete record without CM4 clears that history. Empty compressed CM4 also
requires known version history. Each call starts with fresh state.

## Build and test

```sh
python3 -B tool/dolby_reference/probes/build_stream_inspector.py \
  --probes "$cached_verified_probes" --output "$new_build_dir" --compressed-cm4
CARGO_HOME="$cached_verified_probes/cargo-home" \
RUSTC="$cached_verified_probes/rust-sysroot/bin/rustc" \
CARGO_TARGET_DIR="$new_build_dir/target" \
cargo build --locked --offline --release \
  --manifest-path "$new_build_dir/inspector/Cargo.toml" --examples
YL_RUN_CM4_PROVENANCE=1 \
YL_DOVI_INSPECTOR="$new_build_dir/target/release/yl-dovi-stream-inspector" \
YL_DOVI_CM4_FIXTURE="$new_build_dir/target/release/examples/compressed_cm4_fixture" \
YL_DOVI_UPSTREAM_INSPECTOR="$unmodified_inspector" \
python3 -B -m unittest discover -s tool/dolby_reference -p test_compressed_cm4.py -v
```

The optional build applies a checked overlay only to a fresh extracted copy.
All inputs and expected results are checked before the first patch write.
No fallback is attempted on mismatch. `build-receipt.json` and stdout identify
the parser variant, archive, overlay, patched files and executable. The source
archive, package dependencies and player are not modified. Removing the flag
creates an upstream build with its original rejection behavior.

Integration prerequisites match the P8 fixture: host FFmpeg/libx265, compiler,
pkg-config and libavformat/libavcodec/libavutil headers. Explicit opt-in fails
if they or the executable paths are missing. Default runs skip four integration
tests. `YL_RUN_P8_PROVENANCE` separately enables the previous P8 suite.

The generated 12-frame 10-bit MP4 exercises B-frame reorder, complete/ compressed
records, static L6/L10/L254 inheritance, reset, dynamic expiration, and L8's
10/12/13/19/25-byte lengths with multiple target indices. The independent
`cm4_ffmpeg_fixture.c` decodes the original RPU-bearing MP4 through FFmpeg with
strict errors/CRC checks and reads public `AVDOVIMetadata` side data. It shares
neither the Python resolver nor the patched library. Tests compare per-PTS block
identities and transmitted fields; extra optional L8 fields in FFmpeg must be
zero. The original suite covers L9/L10 short forms; the optional
[wire suite](CM4_WIRE_CONTRACTS.md) adds long forms and raw parser negatives.
This probe is a bounded
test oracle for the generated fixture, not a general metadata exporter.

## Still open

This closes the tested compressed-CM4 transport restriction only in the explicit
research variant. The default upstream limitation, captured real compressed
media, arbitrary CM4 versions/unknown levels, cross-ID/missing headers/default
DM, full mapping/trim/NLQ/resampling, independent picture target contracts and
tolerances, physical output and licensed/device qualification remain open.
Schemas 1/2/5 are unchanged; `effective_metadata_resolved=false`, mapping quality
and native DV remain `external_missing`. A field match proves no pixel-mapping
quality and promotes no CAP-DV status.
