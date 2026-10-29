# CM4 wire contracts and long-form primary coordinates

This extends the optional research verification, not the player or its metadata
admission. The upstream parser and compressed-CM4 overlay are unchanged.

## Independent long-form comparison

The test-only FFmpeg oracle now exports exact AVRational pairs for L9 (17-byte)
and L10 (21-byte) custom primaries, in addition to their existing short forms.
The pinned FFmpeg n8.0.1 `get_cie_xy` reads signed 16-bit values divided by 32767:
https://github.com/FFmpeg/FFmpeg/blob/n8.0.1/libavcodec/dovi_rpudec.c
Libdovi stores the same words as unsigned 16-bit integers. The comparison checks
these representations exactly, without floats or normalization. This establishes
raw input agreement, not a normative interpretation or physical display gamut.

A generated 12-frame video covers static L10 inheritance, full-record reset,
per-packet long L9, B-frame reorder and source packet/PTS/POC binding. One record
explicitly exercises raw words 1, 32767, 32768 and 65535; its negative FFmpeg
coordinates are synthetic wire boundaries, not valid display targets.

## Actual raw parser negatives

`wire_fixture.rs` is imported only by tests/examples. It uses field encoders but
omits object-level admission to produce otherwise unreachable raw negative
records, with recomputed CRC-32/MPEG-2. Legal controls must exactly match the
normal library writer; the known CRC vector is checked separately. Neither the
inspector nor its production parsing library imports this generator.

Six cases are tested: complete CM4 missing L254; compressed static L254;
compressed static L10; duplicate L3; unknown L216; duplicate L8 target. Both
parsers are invoked on real framed NAL bytes. Some cases are intentionally
accepted by upstream parsing: compressed L254 is then rejected by the strict
state contract, and duplicate L8 target is rejected by the state resolver in
both variants. Those are not described as parser-level rejection. Every case is
also inserted after a valid first packet in MP4 and passed through the real
metadata/decode wrapper; failure must publish no trace.

The helper directly uses the already locked bitvec_helpers 4.0.2 as a **dev**
dependency with the same minimal bitstream-io features as libdovi. No new package
version, player dependency or overlay change is introduced.

## Run

Build both inspector variants as documented in COMPRESSED_CM4.md; build the
research variant's examples with the same offline Rust environment and
`cargo build --locked --offline --release --manifest-path "$build/inspector/Cargo.toml" --examples`.
Then:

```sh
YL_RUN_CM4_WIRE=1 \
YL_DOVI_INSPECTOR="$build/target/release/yl-dovi-stream-inspector" \
YL_DOVI_LONG_CM4_FIXTURE="$build/target/release/examples/long_cm4_fixture" \
YL_DOVI_RAW_CM4_FIXTURE="$build/target/release/examples/raw_cm4_cases" \
YL_DOVI_UPSTREAM_INSPECTOR="$upstream_inspector" \
python3 -B -m unittest discover -s tool/dolby_reference -p test_cm4_wire.py -v
```

This enables six integration tests independently of the earlier opt-ins. Missing
paths or host FFmpeg/compiler prerequisites fail; default runs skip them. Prior
P8 and short-CM4 tests retain their own opt-ins.

Captured real compressed media, arbitrary versions/malformed inputs, full
mapping/trim/NLQ/resampling, independent image targets/tolerances, device and
license qualification remain open. The six raw cases are a bounded regression
set, not complete parser fuzzing or format conformance. No CAP status is raised.
