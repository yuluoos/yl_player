# Independent DTS Core stereo PCM check

Use the same-build matrix archive and its packaged codec bridge. The upstream
reference is a standalone Rust decoder. The driver keeps one synthesis state
across the original frame sequence and writes interleaved S32LE. FFmpeg
stream-copies the compressed input. The checker verifies packet hashes, decodes
the bridge to Float32, and compares the full stream and seven PCM windows per
transport in their original channel order.

From the repository root, in a fresh build directory:

```sh
ref=build/dts-reference-replay
git clone https://github.com/OxideAV/oxideav-dts.git "$ref"
git -C "$ref" checkout --detach ec55712f152b93a7638aab3e5c297532d7aa23ae
mkdir -p "$ref/examples"
cp tool/media_matrix/dts_reference/yl_dts_reference.rs "$ref/examples/"
cp tool/media_matrix/dts_reference/Cargo.lock "$ref/"
cargo build --locked --manifest-path "$ref/Cargo.toml" --release --no-default-features --example yl_dts_reference
app=build/macos-format-matrix-20261103/final-aot-matrix.app
matrix=docs/superpowers/reports/evidence/2026-11-03-macos-qualified-format-matrix/final-matrix
python3 -B tool/media_matrix/dts_reference/verify.py \
  "$app/Contents/Frameworks/YlFFmpegBridge.framework/YlFFmpegBridge" \
  "$ref/target/release/examples/yl_dts_reference" "$matrix" build/dts-reference-result.json
```

Upstream declares Rust 1.95. The recorded build used Rust 1.94.0 with
`--ignore-rust-version` and the existing local registry cache. Output is
normalized by 2³¹. The capture clock stamps each sample from its packet's
Matroska PTS at 48 kHz. Use the same integer microsecond truncation to locate
the window, including 10/11 ms PTS increments for 512-frame packets.
